%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2015 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc This is a metadata service for the machi FLU which currently
%% tracks the mappings between filenames and file proxies.
%%
%% The service takes a given hash space and spreads it out over a
%% pool of N processes which are responsible for 1/Nth the hash 
%% space. When a user requests an operation on a particular file
%% the filename is hashed into the hash space and the request
%% forwarded to a particular manager responsible for that slice
%% of the hash space.
%%
%% The current hash implementation is `erlang:phash2/1' which has
%% a range between 0..2^27-1 or 134,217,727. 

-module(machi_flu_metadata_mgr).
-behaviour(gen_server).


-define(MAX_MGRS, 10). %% number of managers to start by default.
-define(HASH(X), erlang:phash2(X)). %% hash algorithm to use
-define(TIMEOUT, 10 * 1000). %% 10 second timeout

-record(state, {name    :: atom(),
                datadir :: string(),
                tid     :: ets:tid()
               }).

%% This record goes in the ets table where prefix is the key
-record(md, {filename          :: string(), 
             proxy_pid         :: undefined|pid(),
             mref              :: undefined|reference() %% monitor ref for file proxy
            }).

%% public api
-export([
         start_link/2,
         lookup_manager_pid/1,
         lookup_proxy_pid/1,
         start_proxy_pid/1,
         stop_proxy_pid/1
        ]).

%% gen_server callbacks
-export([
         init/1,
         handle_cast/2,
         handle_call/3,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

%% Public API

start_link(Name, DataDir) when is_atom(Name) andalso is_list(DataDir) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, DataDir], []).

lookup_manager_pid({file, Filename}) ->
    whereis(get_manager_atom(Filename)).

lookup_proxy_pid({file, Filename}) ->
    gen_server:call(get_manager_atom(Filename), {proxy_pid, Filename}, ?TIMEOUT).

start_proxy_pid({file, Filename}) ->
    gen_server:call(get_manager_atom(Filename), {start_proxy_pid, Filename}, ?TIMEOUT).

stop_proxy_pid({file, Filename}) ->
    gen_server:call(get_manager_atom(Filename), {stop_proxy_pid, Filename}, ?TIMEOUT).

%% gen_server callbacks
init([Name, DataDir]) ->
    Tid = ets:new(Name, [{keypos, 2}, {read_concurrency, true}, {write_concurrency, true}]),
    {ok, #state{ name = Name, datadir = DataDir, tid = Tid}}.

handle_cast(Req, State) ->
    lager:warning("Got unknown cast ~p", [Req]),
    {noreply, State}.

handle_call({proxy_pid, Filename}, _From, State = #state{ tid = Tid }) ->
    Reply = case lookup_md(Tid, Filename) of
                not_found -> undefined;
                R -> R#md.proxy_pid
    end,
    {reply, Reply, State};

handle_call({start_proxy_pid, Filename}, _From, State = #state{ tid = Tid, datadir = D }) ->
    NewR = case lookup_md(Tid, Filename) of
        not_found ->
            start_file_proxy(D, Filename);
        #md{ proxy_pid = undefined } = R0 ->
            start_file_proxy(D, R0);
        #md{ proxy_pid = _Pid } = R1 ->
            R1
    end,
    update_ets(Tid, NewR),
    {reply, {ok, NewR#md.proxy_pid}, State};
handle_call({stop_proxy_pid, Filename}, _From, State = #state{ tid = Tid }) ->
    case lookup_md(Tid, Filename) of
        not_found ->
            ok;
        #md{ proxy_pid = undefined } ->
            ok;
        #md{ proxy_pid = Pid, mref = M } = R ->
            demonitor(M, [flush]),
            machi_file_proxy:stop(Pid),
            update_ets(Tid, R#md{ proxy_pid = undefined, mref = undefined })
    end,
    {reply, ok, State};

handle_call(Req, From, State) ->
    lager:warning("Got unknown call ~p from ~p", [Req, From]),
    {reply, hoge, State}.

handle_info({'DOWN', Mref, process, Pid, normal}, State = #state{ tid = Tid }) ->
    lager:debug("file proxy ~p shutdown normally", [Pid]),
    clear_ets(Tid, Mref),
    {noreply, State};

handle_info({'DOWN', Mref, process, Pid, file_rollover}, State = #state{ tid = Tid }) ->
    lager:info("file proxy ~p shutdown because of file rollover", [Pid]),
    R = get_md_record_by_mref(Tid, Mref),
    [Prefix | _Rest] = machi_util:parse_filename({file, R#md.filename}),

    %% We only increment the counter here. The filename will be generated on the 
    %% next append request to that prefix and since the filename will have a new
    %% sequence number it probably will be associated with a different metadata
    %% manager. That's why we don't want to generate a new file name immediately
    %% and use it to start a new file proxy.
    ok = machi_flu_filename_mgr:increment_prefix_sequence({prefix, Prefix}),

    %% purge our ets table of this entry completely since it is likely the
    %% new filename (whenever it comes) will be in a different manager than
    %% us.
    purge_ets(Tid, R),
    {noreply, State};

handle_info({'DOWN', Mref, process, Pid, wedged}, State = #state{ tid = Tid }) ->
    lager:error("file proxy ~p shutdown because it's wedged", [Pid]),
    clear_ets(Tid, Mref),
    {noreply, State};
handle_info({'DOWN', Mref, process, Pid, Error}, State = #state{ tid = Tid }) ->
    lager:error("file proxy ~p shutdown because ~p", [Pid, Error]),
    clear_ets(Tid, Mref),
    {noreply, State};


handle_info(Info, State) ->
    lager:warning("Got unknown info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("Shutting down because ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Private functions

compute_hash(Data) ->
    ?HASH(Data).

compute_worker(Hash) ->
    Hash rem ?MAX_MGRS.

build_metadata_mgr_name(N) when is_integer(N) ->
    list_to_atom("machi_flu_metadata_mgr_" ++ integer_to_list(N)).

get_manager_atom(Data) ->
    build_metadata_mgr_name(compute_worker(compute_hash(Data))).

lookup_md(Tid, Data) ->
    case ets:lookup(Tid, Data) of
         [] -> not_found;
        [R] -> R
    end.

start_file_proxy(D, R = #md{filename = F} ) ->
    {ok, Pid} = machi_file_proxy_sup:start_proxy(D, F),
    Mref = monitor(process, Pid),
    R#md{ proxy_pid = Pid, mref = Mref };

start_file_proxy(D, Filename) ->
    start_file_proxy(D, #md{ filename = Filename }).

update_ets(Tid, R) ->
    ets:insert(Tid, R).

clear_ets(Tid, Mref) ->
    R = get_md_record_by_mref(Tid, Mref),
    update_ets(Tid, R#md{ proxy_pid = undefined, mref = undefined }).

purge_ets(Tid, R) ->
    ok = ets:delete_object(Tid, R).

get_md_record_by_mref(Tid, Mref) ->
    [R] = ets:match_object(Tid, {md, '_', '_', Mref}),
    R.