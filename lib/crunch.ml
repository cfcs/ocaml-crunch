(*
 * Copyright (c) 2009-2013 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2013      Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

(* repeat until End_of_file is raised *)
let repeat_until_eof fn =
  try while true do fn () done
  with End_of_file -> ()

(* Retrieve file extension , if any, or blank string otherwise *)
let get_extension ~file =
  let rec search_dot i =
    if i < 1 || file.[i] = '/' then None
    else if file.[i] = '.' then Some (String.sub file (i+1) (String.length file - i - 1))
    else search_dot (i - 1) in
  search_dot (String.length file - 1)

(* Walk directory and call walkfn on every file that matches extension ext *)
let walk_directory_tree exts walkfn root_dir =
  (* If extension list is empty then let all through, otherwise white list *)
  let filter_ext =
    match exts with
    | []   -> fun _ -> true
    | exts -> fun ext -> List.mem ext exts
  in
  (* Recursive directory walker *)
  let rec walk dir =
    let dh = Unix.opendir dir in
    repeat_until_eof (fun () ->
      match Unix.readdir dh with
      | "." |".." -> ()
      | f ->
        let n = Filename.concat dir f in
        if Sys.is_directory n then walk n
        else begin
          match get_extension ~file:f with
          |None -> ()
          |Some e ->
            if filter_ext e then
              walkfn root_dir (String.sub n 2 (String.length n - 2))
        end
      );
    Unix.closedir dh in
  Unix.chdir root_dir;
  walk "."

open Arg
open Printf

let file_info = Hashtbl.create 1

let output_generated_by oc binary =
  let t = Unix.gettimeofday () in
  let months = [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun";
                  "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec" |] in
  let days = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |] in
  let time = Unix.gmtime t in
  let date =
    Printf.sprintf "%s, %d %s %d %02d:%02d:%02d GMT"
      days.(time.Unix.tm_wday) time.Unix.tm_mday
      months.(time.Unix.tm_mon) (time.Unix.tm_year+1900)
      time.Unix.tm_hour time.Unix.tm_min time.Unix.tm_sec in
  fprintf oc "(* Generated by: %s \n\
             \  Creation date: %s *)\n\n" binary date

let output_header oc binary =
  output_generated_by oc binary;
  fprintf oc "module Internal = struct\n";
  fprintf oc "let file_chunks = function\n"

let output_file oc root name =
  let full_name = Filename.concat root name in
  let stats = Unix.stat full_name in
  let size = stats.Unix.st_size in
  Hashtbl.add file_info name size;
  fprintf oc " | \"%s\" | \"/%s\" -> Some [" (String.escaped name) (String.escaped name);
  let fin = open_in (Filename.concat root name) in
  let buf = Buffer.create size in
  Buffer.add_channel buf fin size;
  let s = Buffer.contents buf in
  close_in fin;
  (* Split the file as a series of chunks, of size up to 4096 (to simulate reading sectors) *)
  let sec = 4096 in (* sector size *)
  let rec consume idx =
    if idx = size then fprintf oc "]\n"; (* EOF *)
    if idx+sec < size then begin
      fprintf oc "\"%s\";\n" (String.escaped (String.sub s idx sec));
      consume (idx+sec);
    end else begin (* final chunk, short *)
      fprintf oc "\"%s\" ]\n" (String.escaped (String.sub s idx (size-idx)));
    end
  in
  consume 0

let output_footer oc =
  fprintf oc " | _ -> None\n";
  fprintf oc "\n";
  fprintf oc "let file_list = [";
  Hashtbl.iter (fun k _ ->  fprintf oc "\"%s\"; " (String.escaped k)) file_info;
  fprintf oc " ]\n";
  fprintf oc "let size = function\n";
  Hashtbl.iter (fun name size ->
      fprintf oc " |\"%s\" |\"/%s\" -> Some %dL\n" (String.escaped name) (String.escaped name) size
    ) file_info;
  fprintf oc " |_ -> None\n\n";
  fprintf oc "end\n\n"

let output_simple_skeleton oc =
  output_string oc "
let file_list = Internal.file_list
let size name = Internal.size name

let read name =
  match Internal.file_chunks name with
  | None   -> None
  | Some c -> Some (String.concat \"\" c)"

let output_lwt_skeleton_ml oc =
  fprintf oc "
open Lwt

type t = unit

type error =
  | Unknown_key of string

type id = unit

type 'a io = 'a Lwt.t

type page_aligned_stream = Cstruct.t Lwt_stream.t

let size () name =
  match Internal.size name with
  | None   -> return (`Error (Unknown_key name))
  | Some s -> return (`Ok s)

let read () name =
  match Internal.file_chunks name with
  | None   -> return (`Error (Unknown_key name))
  | Some c ->
     let chunks = ref c in
     let get () =
       match !chunks with
       | hd :: tl ->
         chunks := tl;
         let pg = Cstruct.of_bigarray (Io_page.get 1) in
         let len = String.length hd in
         Cstruct.blit_from_string hd 0 pg 0 len;
         return (Some (Cstruct.sub pg 0 len))
       | [] -> return None
     in
     return (`Ok (Lwt_stream.from get))

let return_ok = return (`Ok ())

let connect () = return_ok

let disconnect () = return_unit
"

let output_lwt_skeleton_mli oc =
  fprintf oc "
include V1.KV_RO
  with type id = unit
   and type 'a io = 'a Lwt.t
   and type page_aligned_stream = Cstruct.t Lwt_stream.t"
