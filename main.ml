(*
 * bibtex2html - A BibTeX to HTML translator
 * Copyright (C) 1997 Jean-Christophe FILLIATRE
 * 
 * This software is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation.
 * 
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * 
 * See the GNU General Public License version 2 for more details
 * (enclosed in the file GPL).
 *)

(* $Id: main.ml,v 1.26 1999-06-29 16:50:53 marche Exp $ *)

(* options *)

let excluded = ref ([] : string list)
let add_exclude k = excluded := k :: !excluded
let style = ref "plain"
let command = ref "bibtex -min-crossrefs=1000"

type sort = Unsorted | By_date | By_author
let sort = ref Unsorted
let reverse_sort = ref false

let ignore_bibtex_errors = ref false

let expand_abbrev_in_bib_output = ref true

(* optional citation file *)

let use_cite_file = ref false
let citations = ref ([] : string list)
let add_citations file =
  try
    let chan = open_in file
    and buf = Buffer.create 1024 in
      try
	while true do
	  Buffer.add_char buf (input_char chan)
	done
      with
	  End_of_file ->
	    close_in chan;
	    citations :=
	      (Str.split (Str.regexp "[ \t\n]+") (Buffer.contents buf)) @
	      !citations
  with
      Sys_error msg ->
	prerr_endline ("Cannot open citation file ("^msg^")");
	exit 1

  
(* sort of entries *)

module KeyMap = Map.Make(struct type t = string let compare = compare end)

let keep_combine combine l1 l2 =
  let map = List.fold_left (fun m ((_,k,_) as e) -> KeyMap.add k e m)
	      KeyMap.empty l2 in
  let rec keep_rec = function
      [] ->
	[]
    | ((_,k,_) as x)::rem ->
	if not (List.mem k !excluded) then
	  try
	    let y = KeyMap.find k map in
	      (combine x y) :: (keep_rec rem)
	  with Not_found -> keep_rec rem
	else
	  keep_rec rem
  in
    keep_rec l1

let combine_f (c,_,b) e = c,b,e

let rev_combine_f x y = combine_f y x

let sort_entries entries bibitems =
  Printf.printf "Sorting..."; flush stdout;
  let el =
    if !sort = By_author then 
      keep_combine combine_f bibitems entries
    else
      keep_combine rev_combine_f entries bibitems
  in
  let sl = 
    if !sort = By_date then
      Sort.list (fun (_,_,e1) (_,_,e2) -> Expand.date_order e1 e2) el
    else
      el in
  Printf.printf "ok.\n"; flush stdout;
  if !reverse_sort then List.rev sl else sl


(* We use BibTeX itself to format the entries. Operations:
 *
 * 1. create an auxiliary file tmp.aux
 * 2. call bibtex on it
 * 3. read the resulting tmp.bbl file to get the formatted entries
 *)

let create_aux_file fbib tmp =
  let ch = open_out (tmp ^ ".aux") in
  output_string ch "\\relax\n\\bibstyle{";
  output_string ch !style;
  output_string ch "}\n";
  if !use_cite_file then
    List.iter 
      (fun k -> output_string ch ("\\citation{" ^ k ^ "}\n"))
      !citations
  else
    output_string ch "\\citation{*}\n";
  output_string ch "\\bibdata{";
  output_string ch (Filename.chop_suffix fbib ".bib");
  output_string ch "}\n";
  close_out ch

let rm f = try Sys.remove f with _ -> ()

let clean tmp =
  if not !Translate.debug then begin
    rm (tmp ^ ".aux");
    rm (tmp ^ ".blg");
    rm (tmp ^ ".bbl");
    rm tmp
  end

let call_bibtex tmp =
  Printf.printf "calling BibTeX..."; flush stdout;
  match 
    Sys.command (Printf.sprintf "%s %s" !command tmp)
  with
      0 -> Printf.printf "\n"; flush stdout
    | n ->
	if !ignore_bibtex_errors then begin
	  Printf.printf "error %d (ignored)\n" n;
	  flush stdout
      	end else begin
	  Printf.fprintf stderr "error %d while running bibtex\n" n;
	  exit n
	end

let read_one_biblio lb =
  let rec read_items acc lb =
    try
      let (_,k,_) as item = Bbl_lexer.bibitem lb in
	if !Translate.debug then begin
	  Printf.printf "[%s]" k; flush stdout
  	end;
      read_items (item::acc) lb
    with
	Bbl_lexer.End_of_biblio -> List.rev acc 
  in
  let name = Bbl_lexer.biblio_header lb in
  let items = read_items [] lb in
    (name,items)

let read_biblios lb =
  let rec read acc lb =
    try
      let b = read_one_biblio lb in
	read (b::acc) lb
    with
	End_of_file -> List.rev acc
  in
    read [] lb

let read_bbl tmp =
  let fbbl = tmp ^ ".bbl" in
  Printf.printf "Reading %s..." fbbl; flush stdout;
  let ch = open_in fbbl in
  let lexbuf = Lexing.from_channel ch in
  let biblios = read_biblios lexbuf in
  close_in ch;
  clean tmp;
  Printf.printf "ok ";
  List.iter (fun (_,items) ->
	       Printf.printf "(%d entries)" (List.length items))
    biblios;
  Printf.printf "\n"; flush stdout;
  biblios

let get_biblios fbib =
  let tmp = Filename.temp_file "bib2html" "" in
  try
    create_aux_file fbib tmp;
    call_bibtex tmp;
    read_bbl tmp
  with
    e -> clean tmp ; raise e


let translate fullname basename =
  let input_bib = Readbib.read_entries_from_file fullname in
  let entries = Expand.expand input_bib in
  let biblios = get_biblios fullname in
  let sb = List.map 
	     (fun (name,bibitems) -> (name,sort_entries entries bibitems))
	     biblios in
  Translate.format_list 
    basename 
    (if !expand_abbrev_in_bib_output then 
       Bibtex.expand_abbrevs input_bib 
     else input_bib) 
    sb 
    (if !use_cite_file then
       let keys = 
	 List.fold_right 
	   (fun s e -> Bibtex.KeySet.add s e) !citations Bibtex.KeySet.empty in
       let keys =
	 List.fold_right 
	   (fun s e -> Bibtex.KeySet.remove s e) !excluded keys in
	 Some (Bibfilter.saturate input_bib keys)
     else None)


(* reading macros in a file *)

let read_macros f =
  let chan = open_in f in
  let lb = Lexing.from_channel chan in
    Latexscan.read_macros lb;
    close_in chan


(* command line parsing *)

let usage () =
  prerr_endline "";
  prerr_endline "Usage: bibtex2html <options> filename";
  prerr_endline "  -s style   BibTeX style (plain, alpha, ...)";
  prerr_endline "  -c command BibTeX command (otherwise bibtex is searched in your path)";
  prerr_endline "  -d         sort by date";
  prerr_endline "  -a         sort as BibTeX (usually by author)";
  prerr_endline "  -u         unsorted i.e. same order as in .bib file (default)";
  prerr_endline "  -r         reverse the sort";
  prerr_endline "  -t         title of the HTML file (default is the filename)";
  prerr_endline "  -i         ignore BibTeX errors";
  prerr_endline "  -both      produce versions with and without abstracts";
  prerr_endline "  -multiple  produce one file per entry";
  prerr_endline "  -nodoc     only produces the body of the HTML documents";
  prerr_endline "  -nokeys    do not print the BibTeX keys";
  prerr_endline "  -noabstract";
  prerr_endline "             do not print the abstracts (if any)";
  prerr_endline "  -nofooter  do not print the footer (bibtex2html web link)";
  prerr_endline "  -noexpand  do not expand abbreviations in the BibTeX output";
  prerr_endline "  -suffix s  give an alternate suffix for HTML files";
  prerr_endline "  -citefile f";
  prerr_endline "             read keys to include from file f";
  prerr_endline "  -e key     exclude an entry";
  prerr_endline "  -m file    read (La)TeX macros in file";
  prerr_endline "  -f field   add a web link for that BibTeX field";
  prerr_endline "  -debug     verbose mode (to find incorrect BibTeX entries)";
  prerr_endline "  -v         print version and exit";
  exit 1

let copying () =
  print_endline "
This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License version 2, as
published by the Free Software Foundation.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License version 2 for more details
(enclosed in the file GPL).";
  flush stdout

let banner () =
  Printf.printf "This is bibtex2html version %s, compiled on %s\n"
    Version.version Version.date;
  Printf.printf "Copyright (c) 1997,1998,1999 Jean-Christophe Filli�tre\n";
  Printf.printf "This is free software with ABSOLUTELY NO WARRANTY (use option -warranty)\n";
  flush stdout

let parse () =
  let rec parse_rec = function

    (* General aspect of the web page *)
    | ("-t" | "--title") :: s :: rem ->
	Translate.title := s ; Translate.title_spec := true; parse_rec rem
    | ("-t" | "--title") :: [] ->
	usage()
    | ("-s" | "--style") :: s :: rem ->
	style := s ; parse_rec rem
    | ("-s" | "--style") :: [] ->
	usage()
    | ("-noabstract" | "--no-abstract") :: rem ->
	Translate.print_abstract := false; parse_rec rem
    | ("-nokeys" | "--no-keys") :: rem -> 
	Translate.nokeys := true ; parse_rec rem
    | ("-nofooter" | "--no-footer") :: rem ->
	Translate.print_footer := false; parse_rec rem
    | ("-f" | "--field") :: s :: rem ->
	Translate.add_field s; parse_rec rem
    | ("-f" | "--field") :: [] ->
	usage()
    | ("-multiple" | "--multiple") :: rem ->
	Translate.multiple := true; parse_rec rem
    | ("-both" | "--both") :: rem ->
	Translate.both := true; parse_rec rem
 
    (* Controlling the translation *)
    | ("-m" | "--macros-from") :: f :: rem ->
	read_macros f; parse_rec rem
    | ("-m" | "--macros-from") :: [] ->
	usage()
 
    (* Sorting the entries *)
    | ("-d" | "--sort-by-date") :: rem ->
	sort := By_date ; parse_rec rem
    | ("-a" | "--sort-as-bibtex") :: rem ->
	sort := By_author ; parse_rec rem
    | ("-u" | "--unsorted") :: rem ->
	sort := Unsorted ; parse_rec rem
    | ("-r" | "--reverse-sort") :: rem ->
	reverse_sort := true ; parse_rec rem

    (* Options for selecting keys *)
    | ("-citefile") :: f :: rem ->
	use_cite_file := true;
	add_citations f;
	parse_rec rem
    | ("--citefile") :: [] ->
	usage()
    | ("-e" | "--exclude") :: k :: rem ->
	add_exclude k ; parse_rec rem
    | ("-e" | "--exclude") :: [] ->
	usage()
 
    (* Miscellaneous options *)
    | ("-nodoc" | "--no-doc") :: rem -> 
	Translate.nodoc := true ; parse_rec rem
    | ("-noexpand" | "--no-expand") :: rem -> 
	expand_abbrev_in_bib_output := false ; parse_rec rem
    | ("-i" | "--ignore-errors") :: rem ->
	ignore_bibtex_errors := true ; parse_rec rem
    | ("-suffix" | "--suffix") :: s :: rem ->
	Translate.suffix := s ; parse_rec rem
    | ("-suffix" | "--suffix") :: [] ->
	usage()
    | ("-c" | "--command") :: s :: rem ->
	command := s ; parse_rec rem
    | ("-c" | "--command") :: [] ->
	usage()
    | ("-h" | "-help" | "-?" | "--help") :: rem ->
	Printf.printf
     "\nOn-line documentation at http://www.lri.fr/~filliatr/bibtex2html/\n\n";
	usage ()
    | ("-v" | "-version" | "--version") :: _ ->
	exit 0
    | ("-warranty" | "--warranty") :: _ ->
	copying(); exit 0

    | ("-debug" | "--debug") :: rem ->
	Translate.debug := true ; parse_rec rem

    | [f] -> f
    | _ -> usage ()
  in 
    parse_rec (List.tl (Array.to_list Sys.argv))


(* main *)

let main () =
  banner();
  let fbib = parse () in
  let f =
    let basename = Filename.basename fbib in
    if Filename.check_suffix basename ".bib" then
      Filename.chop_suffix basename ".bib"
    else begin
      prerr_endline "BibTeX file must have suffix .bib !";
      usage ()
    end
  in

  Latexmacros.init_style_macros !style;

  if not !Translate.title_spec then Translate.title := f;

  (* producing the documents *)
  translate fbib f

let _ = Printexc.catch main ()
