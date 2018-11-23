-module(ai_string_compat).
-compile({inline, [stack/2,append/2]}).
-export([prefix/2,find/3,slice/2,slice/3]).
-define(ASCII_LIST(CP1,CP2), CP1 < 256, CP2 < 256, CP1 =/= $\r).
  
-spec prefix(String::unicode:chardata(), Prefix::unicode:chardata()) ->
                    'nomatch' | unicode:chardata().
prefix(Str, Prefix0) ->
    Result = 
		case unicode:characters_to_list(Prefix0) of
            [] -> Str;
            Prefix -> prefix_1(Str, Prefix)
        end,
    case Result of
        [] when is_binary(Str) -> <<>>;
        Res -> Res
    end.

prefix_1(Cs0, [GC]) ->
    case ai_unicode_util:gc(Cs0) of
        [GC|Cs] -> Cs;
        _ -> nomatch
    end;
prefix_1([CP|Cs], [Pre|PreR]) when is_integer(CP) ->
    case CP =:= Pre of
        true -> prefix_1(Cs,PreR);
        false -> nomatch
    end;
prefix_1(<<CP/utf8, Cs/binary>>, [Pre|PreR]) ->
    case CP =:= Pre of
        true -> prefix_1(Cs,PreR);
        false -> nomatch
    end;
prefix_1(Cs0, [Pre|PreR]) ->
    case ai_unicode_util:cp(Cs0) of
        [Pre|Cs] ->  prefix_1(Cs,PreR);
        _ -> nomatch
end.
-spec find(String, SearchPattern, Dir) -> unicode:chardata() | 'nomatch' when
      String::unicode:chardata(),
      SearchPattern::unicode:chardata(),
      Dir::atom().
find(String, "", _) -> String;
find(String, <<>>, _) -> String;
find(String, SearchPattern, leading) ->
    find_l(String, unicode:characters_to_list(SearchPattern));
find(String, SearchPattern, trailing) ->
	find_r(String, unicode:characters_to_list(SearchPattern), nomatch).
find_l([C1|Cs]=Cs0, [C|_]=Needle) when is_integer(C1) ->
    case C1 of
        C ->
            case prefix_1(Cs0, Needle) of
                nomatch -> find_l(Cs, Needle);
                _ -> Cs0
            end;
        _ ->
            find_l(Cs, Needle)
    end;
find_l([Bin|Cont0], Needle) when is_binary(Bin) ->
    case bin_search_str(Bin, 0, Cont0, Needle) of
        {nomatch, _, Cont} ->
            find_l(Cont, Needle);
        {_Before, Cs, _After} ->
            Cs
    end;
find_l(Cs0, [C|_]=Needle) when is_list(Cs0) ->
    case ai_unicode_util:cp(Cs0) of
        [C|Cs] ->
            case prefix_1(Cs0, Needle) of
                nomatch -> find_l(Cs, Needle);
                _ -> Cs0
            end;
        [_C|Cs] ->
            find_l(Cs, Needle);
        [] -> nomatch
    end;
find_l(Bin, Needle) ->
    case bin_search_str(Bin, 0, [], Needle) of
        {nomatch,_,_} -> nomatch;
        {_Before, [Cs], _After} -> Cs
    end.

find_r([Cp|Cs]=Cs0, [C|_]=Needle, Res) when is_integer(Cp) ->
    case Cp of
        C ->
            case prefix_1(Cs0, Needle) of
                nomatch -> find_r(Cs, Needle, Res);
                _ -> find_r(Cs, Needle, Cs0)
            end;
        _ ->
            find_r(Cs, Needle, Res)
    end;
find_r([Bin|Cont0], Needle, Res) when is_binary(Bin) ->
    case bin_search_str(Bin, 0, Cont0, Needle) of
        {nomatch,_,Cont} ->
            find_r(Cont, Needle, Res);
        {_, Cs0, _} ->
            [_|Cs] = ai_unicode_util:gc(Cs0),
            find_r(Cs, Needle, Cs0)
    end;
find_r(Cs0, [C|_]=Needle, Res) when is_list(Cs0) ->
    case ai_unicode_util:cp(Cs0) of
        [C|Cs] ->
            case prefix_1(Cs0, Needle) of
                nomatch -> find_r(Cs, Needle, Res);
                _ -> find_r(Cs, Needle, Cs0)
            end;
        [_C|Cs] ->
            find_r(Cs, Needle, Res);
        [] -> Res
    end;
find_r(Bin, Needle, Res) ->
    case bin_search_str(Bin, 0, [], Needle) of
        {nomatch,_,_} -> Res;
        {_Before, [Cs0], _After} ->
            <<_/utf8, Cs/binary>> = Cs0,
            find_r(Cs, Needle, Cs0)
end.

bin_search_str(Bin0, Start, [], SearchCPs) ->
    Compiled = binary:compile_pattern(unicode:characters_to_binary(SearchCPs)),
    bin_search_str_1(Bin0, Start, Compiled, SearchCPs);
bin_search_str(Bin0, Start, Cont, [CP|_]=SearchCPs) ->
    First = binary:compile_pattern(<<CP/utf8>>),
    bin_search_str_2(Bin0, Start, Cont, First, SearchCPs).

bin_search_str_1(Bin0, Start, First, SearchCPs) ->
    <<_:Start/binary, Bin/binary>> = Bin0,
    case binary:match(Bin, First) of
        nomatch -> {nomatch, byte_size(Bin0), []};
        {Where0, _} ->
            Where = Start+Where0,
            <<Keep:Where/binary, Cs0/binary>> = Bin0,
            case prefix_1(Cs0, SearchCPs) of
                nomatch ->
                    <<_/utf8, Cs/binary>> = Cs0,
                    KeepSz = byte_size(Bin0) - byte_size(Cs),
                    bin_search_str_1(Bin0, KeepSz, First, SearchCPs);
                [] ->
                    {Keep, [Cs0], <<>>};
                Rest ->
                    {Keep, [Cs0], Rest}
            end
    end.

bin_search_str_2(Bin0, Start, Cont, First, SearchCPs) ->
    <<_:Start/binary, Bin/binary>> = Bin0,
    case binary:match(Bin, First) of
        nomatch -> {nomatch, byte_size(Bin0), Cont};
        {Where0, _} ->
            Where = Start+Where0,
            <<Keep:Where/binary, Cs0/binary>> = Bin0,
            [GC|Cs]=ai_unicode_util:gc(Cs0),
            case prefix_1(stack(Cs0,Cont), SearchCPs) of
                nomatch when is_binary(Cs) ->
                    KeepSz = byte_size(Bin0) - byte_size(Cs),
                    bin_search_str_2(Bin0, KeepSz, Cont, First, SearchCPs);
                nomatch ->
                    {nomatch, Where, stack([GC|Cs],Cont)};
                [] ->
                    {Keep, [Cs0|Cont], <<>>};
                Rest ->
                    {Keep, [Cs0|Cont], Rest}
            end
end.
%% Slice a string and return rest of string
%% Note: counts grapheme_clusters
-spec slice(String, Start) -> Slice when
      String::unicode:chardata(),
      Start :: non_neg_integer(),
      Slice :: unicode:chardata().
slice(CD, N) when is_integer(N), N >= 0 ->
    case slice_l0(CD, N) of
        [] when is_binary(CD) -> <<>>;
        Res -> Res
    end.

-spec slice(String, Start, Length) -> Slice when
      String::unicode:chardata(),
      Start :: non_neg_integer(),
      Length :: 'infinity' | non_neg_integer(),
      Slice :: unicode:chardata().
slice(CD, N, Length)
  when is_integer(N), N >= 0, is_integer(Length), Length > 0 ->
    case slice_l0(CD, N) of
        [] when is_binary(CD) -> <<>>;
        L -> slice_trail(L, Length)
    end;
slice(CD, N, infinity) ->
    case slice_l0(CD, N) of
        [] when is_binary(CD) -> <<>>;
        Res -> Res
    end;
slice(CD, _, 0) ->
    case is_binary(CD) of
        true  -> <<>>;
        false -> []
end.

slice_l0(<<CP1/utf8, Bin/binary>>, N) when N > 0 ->
    slice_lb(Bin, CP1, N);
slice_l0(L, N) ->
    slice_l(L, N).

slice_l([CP1|[CP2|_]=Cont], N) when ?ASCII_LIST(CP1,CP2),N > 0 ->
    slice_l(Cont, N-1);
slice_l(CD, N) when N > 0 ->
    case ai_unicode_util:gc(CD) of
        [_|Cont] -> slice_l(Cont, N-1);
        [] -> []
    end;
slice_l(Cont, 0) ->
    Cont.

slice_lb(<<CP2/utf8, Bin/binary>>, CP1, N) when ?ASCII_LIST(CP1,CP2), N > 1 ->
    slice_lb(Bin, CP2, N-1);
slice_lb(Bin, CP1, N) ->
    [_|Rest] = ai_unicode_util:gc([CP1|Bin]),
    if N > 1 ->
            case ai_unicode_util:cp(Rest) of
                [CP2|Cont] -> slice_lb(Cont, CP2, N-1);
                [] -> <<>>
            end;
       N =:= 1 ->
            Rest
    end.

slice_trail(Orig, N) when is_binary(Orig) ->
    case Orig of
        <<CP1/utf8, Bin/binary>> when N > 0 ->
            Length = slice_bin(Bin, CP1, N),
            Sz = byte_size(Orig) - Length,
            <<Keep:Sz/binary, _/binary>> = Orig,
            Keep;
        _ -> <<>>
    end;
slice_trail(CD, N) when is_list(CD) ->
    slice_list(CD, N).

slice_list([CP1|[CP2|_]=Cont], N) when ?ASCII_LIST(CP1,CP2),N > 0 ->
    [CP1|slice_list(Cont, N-1)];
slice_list(CD, N) when N > 0 ->
    case ai_unicode_util:gc(CD) of
        [GC|Cont] -> append(GC, slice_list(Cont, N-1));
        [] -> []
    end;
slice_list(_, 0) ->
    [].

slice_bin(<<CP2/utf8, Bin/binary>>, CP1, N) when ?ASCII_LIST(CP1,CP2), N > 0 ->
    slice_bin(Bin, CP2, N-1);
slice_bin(CD, CP1, N) when N > 0 ->
    [_|Bin] = ai_unicode_util:gc([CP1|CD]),
    case ai_unicode_util:cp(Bin) of
        [CP2|Cont] -> slice_bin(Cont, CP2, N-1);
        [] -> 0
    end;
slice_bin(CD, CP1, 0) -> byte_size(CD)+byte_size(<<CP1/utf8>>).

stack(Bin, []) -> Bin;
stack(<<>>, St) -> St;
stack([], St) -> St;
stack(Bin, St) -> [Bin|St].

append(Char, <<>>) when is_integer(Char) -> [Char];
append(Char, <<>>) when is_list(Char) -> Char;
append(Char, Bin) when is_binary(Bin) -> [Char,Bin];
append(Char, Str) when is_integer(Char) -> [Char|Str];
append(GC, Str) when is_list(GC) -> GC ++ Str.