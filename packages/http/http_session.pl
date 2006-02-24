/*  $Id$

    Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        wielemak@science.uva.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2006, University of Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/


:- module(http_session,
	  [ http_set_session_options/1,	% +Options

	    http_session_id/1,		% -SessionId
	    http_current_session/2,	% ?SessionId, ?Data

	    http_session_asserta/1,	% +Data
	    http_session_assert/1,	% +Data
	    http_session_retract/1,	% ?Data
	    http_session_retractall/1,	% +Data
	    http_session_data/1		% ?Data
	  ]).
:- use_module(http_wrapper).
:- use_module(library(debug)).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
HTTP Cookie based session management.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

:- dynamic
	session_setting/1,		% Name(Value)
	current_session/1,		% SessionId
	last_used/2,			% SessionId, Time
	session_data/2.			% SessionId, Data

session_setting(timeout(600)).
session_setting(cookie('swipl_session')).
session_setting(path(/)).

http_set_session_options([]).
http_set_session_options([H|T]) :-
	http_session_option(H),
	http_set_session_options(T).

http_session_option(Option) :-
	functor(Option, Name, Arity),
	functor(Free, Name, Arity),
	retractall(session_setting(Free)),
	assert(session_setting(Option)).

%	http_session_id(-SessionId)
%	
%	Fetch the current session ID from the global request variable.

http_session_id(SessionID) :-
	http_current_request(Request),
	(   memberchk(session(SessionID0), Request)
	->  SessionID = SessionID0
	;   throw(error(existence_error(http_session, _), _))
	).


%	http_session(+RequestIn, -RequestOut, -SessionID)
%	
%	Maintain the notion of a  session   using  a client-side cookie.
%	This must be called first when handling a request that wishes to
%	do session management, after which the possibly modified request
%	must be used for further processing.

http_session(Request, Request, SessionID) :-
	memberchk(session(SessionID0), Request), !,
	SessionID = SessionID0.
http_session(Request0, Request, SessionID) :-
	memberchk(cookie(Cookies), Request0),
	session_setting(cookie(Cookie)),
	memberchk(Cookie=SessionID0, Cookies),
	valid_session_id(SessionID0), !,
	SessionID = SessionID0,
	Request = [session(SessionID)|Request0].
http_session(Request0, Request, SessionID) :-
	http_gc_sessions,		% GC dead sessions
	gen_cookie(SessionID),
	session_setting(cookie(Cookie)),
	session_setting(path(Path)),
	format('Set-Cookie: ~w=~w; path=~w~n', [Cookie, SessionID, Path]),
	Request = [session(SessionID)|Request0],
	open_session(SessionID).

:- multifile
	http:request_expansion/2.

http:request_expansion(Request0, Request) :-
	http_session(Request0, Request, _SessionID).


%	open_session(+SessionID)
%	
%	Open a new session.

open_session(SessionID) :-
	get_time(Now),
	assert(current_session(SessionID)),
	assert(last_used(SessionID, Now)).


%	valid_session_id(+SessionID)
%	
%	Check if this sessionID is known. If so, check the idle time and
%	update the last_used for this session.

valid_session_id(SessionID) :-
	current_session(SessionID),
	get_time(Now),
	(   session_setting(timeout(Timeout)),
	    Timeout > 0
	->  last_used(SessionID, Last),
	    Idle is Now - Last,
	    (	Idle =< Timeout
	    ->  true
	    ;   delete_session(SessionID),
		fail
	    )
	;   true
	),
	retractall(last_used(SessionID, _)),
	assert(last_used(SessionID, Now)).


		 /*******************************
		 *	   SESSION DATA		*
		 *******************************/

http_session_asserta(Data) :-
	http_session_id(SessionId),
	asserta(session_data(SessionId, Data)).

http_session_assert(Data) :-
	http_session_id(SessionId),
	assert(session_data(SessionId, Data)).

http_session_retract(Data) :-
	http_session_id(SessionId),
	retract(session_data(SessionId, Data)).

http_session_retractall(Data) :-
	http_session_id(SessionId),
	retractall(session_data(SessionId, Data)).

http_session_data(Data) :-
	http_session_id(SessionId),
	session_data(SessionId, Data).


		 /*******************************
		 *	     ENUMERATE		*
		 *******************************/

%	http_current_session(?SessionID, ?Data)
%	
%	Enumerate the current sessions and   associated data. The pseudo
%	data element idle(Seconds) provides the idle time. Other data is
%	application specified.

http_current_session(SessionID, Data) :-
	get_time(Now),
	last_used(SessionID, Last),
	Idle is Now - Last,
	(   session_setting(timeout(Timeout)),
	    Timeout > 0
	->  Idle =< Timeout
	;   true
	),
	(   Data = idle(Idle)
	;   session_data(SessionID, Data)
	).


		 /*******************************
		 *	    GC SESSIONS		*
		 *******************************/

delete_session(SessionId) :-
	retractall(current_session(SessionId)),
	retractall(last_used(SessionId, _)),
	retractall(session_data(SessionId, _)).

%	http_gc_sessions/0
%	
%	Delete dead sessions.  When should we be calling this?

http_gc_sessions :-
	session_setting(timeout(Timeout)),
	Timeout > 0, !,
	get_time(Now),
	(   last_used(SessionID, Last),
	    Idle is Now - Last,
	    Idle > Timeout,
	    delete_session(SessionID),
	    fail
	;   true
	).
http_gc_sessions.


		 /*******************************
		 *	       UTIL		*
		 *******************************/

%	gen_cookie(-Cookie)
%	
%	Generate a random cookie that  can  be   used  by  a  browser to
%	identify the current session

gen_cookie(Cookie) :-
	R1 is random(65536),
	R2 is random(65536),
	R3 is random(65536),
	R4 is random(65536),
	sformat(CookieS,
		'~`0t~16r~4|-~`0t~16r~9|-~`0t~16r~14|-~`0t~16r~19|',
		[R1,R2,R3,R4]),
	string_to_list(CookieS, Codes),
	atom_codes(Cookie, Codes).

