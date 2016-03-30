open Core_kernel.Std
open Bap_bundle.Std
open Bap.Std
include Self()
open Cabs
open Option.Monad_infix

type arg_size =
  | Word                        (** same size as CPU word  *)
  | Size of Size.t              (** the specified size     *)

type pos =
  | Ret_0
  | Ret_1
  | Arg of int

type attr = {
  attr_name : string;
  attr_args : string list;
}

type arg = {
  arg_name : string;
  arg_pos  : pos;
  arg_intent : intent;
  arg_size : arg_size;
  arg_attrs : attr list;
}

type fn_proto = {
  args : arg list;
  attrs : attr list;
}

type options = {
  add_headers : string list;
  use_header : string option
}

exception Attr_type   of string * string
exception Attr_index  of int * int
exception Attr_arity  of string


include struct
  let stack mem sp endian sz off =
    let width = Size.in_bits sz in
    let off = Word.of_int ~width (off * (Size.in_bytes sz)) in
    let mem = Bil.var mem in
    let addr = if Word.is_zero off
      then Bil.(var sp)
      else Bil.(var sp + int off) in
    Bil.load ~mem ~addr endian sz

  module IA32  = X86_cpu.IA32
  module AMD64 = X86_cpu.AMD64
  module ARM   = ARM.CPU

  let arm_stack = ARM.(stack mem sp LittleEndian `r32)
  let x86_stack = IA32.(stack mem sp LittleEndian `r32)
  let x64_stack = AMD64.(stack mem sp LittleEndian `r64)

  open Bil
  let abi = function
    | #Arch.arm ->
      ARM.(function
          | Ret_0 -> var r0
          | Ret_1 -> var r1
          | Arg 0 -> var r0
          | Arg 1 -> var r1
          | Arg 2 -> var r2
          | Arg 3 -> var r3
          | Arg n -> arm_stack Int.(n-4))
    | `x86_64 ->
      AMD64.(function
          | Ret_0 -> var rax
          | Ret_1 -> var rdx
          | Arg 0 -> var rdi
          | Arg 1 -> var rsi
          | Arg 2 -> var rdx
          | Arg 3 -> var rcx
          | Arg 4 -> var r.(0)
          | Arg 5 -> var r.(1)
          | Arg n -> x64_stack Int.(n-6))
    | `x86 ->
      IA32.(function
          | Ret_0 -> var rax
          | Ret_1 -> var rdx
          | Arg n -> x86_stack Int.(n+1))
    | _ -> raise Not_found
end

let points = function
  | PTR t | RESTRICT_PTR t | ARRAY (t,_) -> Some t
  | _ -> None

let intent_of_type t = match points t with
  | None -> In
  | Some pointee -> match pointee with
    | CONST _ -> In
    | _ -> Both

let size_of_type typ = match typ with
  | PTR _ -> Word
  | CHAR _ -> Size `r8
  | INT (SHORT,_) -> Size `r16
  | INT (LONG_LONG,_) -> Size `r64
  | FLOAT _ -> Size `r32
  | DOUBLE false -> Size `r64
  | DOUBLE true -> Size `r128
  | _ -> Word

let attr attr_name attr_args = {attr_name; attr_args}

let arg_attrs attrs n =
  let int n =
    try Int.of_string n with exn -> raise (Attr_type ("<int>",n)) in
  let alloc_size args =
    let attr = attr "alloc_size" [] in
    List.map args ~f:int |> function
    | [i] when i = n -> Some attr
    | [i;j] when i = n || j = n -> Some attr
    | [_] | [_;_] -> None
    | _ -> raise (Attr_arity "1 | 2") in
  let format = function
    | [l;i] when int i = n -> Some (attr "format" [l])
    | [_;_] -> None
    | _ -> raise (Attr_arity "2") in
  let nonnull = function
    | [i] when int i = n -> Some (attr "nonnull" [])
    | [_] -> None
    | _ -> raise (Attr_arity "1") in
  List.filter_map attrs ~f:(fun {attr_name; attr_args} ->
      let pick p = p attr_args in
      match attr_name with
      | "alloc_size" -> pick alloc_size
      | "format" -> pick format
      | "nonnull" -> pick nonnull
      | _ -> None)

let restricted = function
  | RESTRICT_PTR _ -> [attr "restricted" []]
  | _ -> []

let warn_unused = List.filter_map ~f:(function
    | {attr_name="warn_unused_result"} -> Some (attr "warn_unused" [])
    | _ -> None)

let arg_of_name attrs n = function
  | (_,VOID,_,_) -> None
  | (name,typ,_,_) -> Some {
      arg_pos = Arg n;
      arg_name = if name <> "" then name else sprintf "x%d" (n+1);
      arg_intent = intent_of_type typ;
      arg_size = size_of_type typ;
      arg_attrs = restricted typ @ arg_attrs attrs n;
    }

let string_of_single_name attrs n (_,_,name) =
  arg_of_name attrs n name

let args_of_single_names attrs =
  List.filter_mapi ~f:(string_of_single_name attrs)

let unuglify = String.strip ~drop:(fun c -> c = '_')

let id_of_attr = function
  | GNU_CST
      ( CONST_INT id
      | CONST_FLOAT id
      | CONST_CHAR id
      | CONST_STRING id) -> Some (unuglify id)
  | GNU_ID id -> Some (unuglify id)
  | _ -> None

let attr = function
  | GNU_EXTENSION | GNU_INLINE | GNU_CST _ | GNU_NONE -> None
  | GNU_ID id -> Some {attr_name = unuglify id; attr_args=[]}
  | GNU_CALL (id,args) -> Some {
      attr_name = unuglify id;
      attr_args = List.filter_map  ~f:id_of_attr args
    }

let make_attrs = List.filter_map ~f:attr


let ret_word attrs n = {
  arg_pos = n;
  arg_name = if n = Ret_1 then "result_ext" else "result";
  arg_intent = Out;
  arg_size = Word;
  arg_attrs = warn_unused attrs;
}

let push = List.map ~f:(fun a -> match a with
    | {arg_pos = Arg n} -> {a with arg_pos = Arg (n+1)}
    | a -> a)

let fn_of_definition = function
  | DECDEF (_,_,[(name, PROTO (ret,args,_vararg),attrs,NOTHING)])
  | FUNDEF ((_,_,(name, PROTO (ret,args,_vararg),attrs,NOTHING)), _) ->
    let attrs = make_attrs attrs in
    let ret_word = ret_word attrs in
    let args = args_of_single_names attrs args in
    let args = match ret with
      | VOID -> args
      | STRUCT _ | CONST (STRUCT _) ->
        {(ret_word (Arg 0)) with arg_intent = In} :: push args
      | INT (LONG_LONG,_) -> args @ [ret_word Ret_0; ret_word Ret_1]
      | _ -> args @ [ret_word Ret_0] in
    Some (name,{args; attrs})
  | _ -> None

let fns_of_definitions =
  List.fold ~init:String.Map.empty ~f:(fun fns defn ->
      match fn_of_definition defn with
      | None -> fns
      | Some (name,data) -> Map.add fns ~key:name ~data)

let protos_of_file file =
  let open Frontc in
  match Frontc.parse_file file stderr with
  | PARSING_ERROR -> raise Parsing.Parse_error
  | PARSING_OK ds -> fns_of_definitions ds


let merge_args =
  Map.merge ~f:(fun ~key (`Left a |`Right a |`Both (_,a)) -> Some a)

let is_api name =
  match String.split ~on:'/' name with
  | ["api"; _] -> true
  | _ -> false

let protos_of_bundle bundle =
  Bundle.list bundle |> List.filter ~f:is_api |>
  List.fold ~init:String.Map.empty ~f:(fun args file ->
      let name = Filename.temp_file "api" ".h" in
      match Bundle.get_file ~name bundle (Uri.of_string file) with
      | None -> args
      | Some uri ->
        let dst = Uri.path uri in
        let finally () = Sys.remove dst in
        let args' = protect ~f:(fun () -> protos_of_file dst) ~finally in
        merge_args args args')

let (>:) s1 s2 e =
  match Size.(in_bits s2 - in_bits s1) with
  | 0 -> e
  | n when n > 0 -> Bil.(cast high n e)
  | n -> Bil.(cast low n e)

let set_arg_attrs attrs arg =
  let set tag arg = Term.set_attr arg tag () in
  let set_format = function
    | [dsl] -> fun arg -> Term.set_attr arg Arg.format dsl
    | _ -> assert false in
  List.fold_right attrs ~init:arg ~f:(fun {attr_name; attr_args} ->
      match attr_name with
      | "alloc_size" -> set Arg.alloc_size
      | "nonnull" -> set Arg.nonnull
      | "warn_unused" -> set Arg.warn_unused
      | "format" -> set_format attr_args
      | _ -> ident)

let term_of_arg arch sub
    {arg_name; arg_size; arg_intent; arg_pos; arg_attrs} =
  let word_size = Arch.addr_size arch in
  let size = match arg_size with
    | Word -> (word_size :> Size.t)
    | Size size -> size in
  let typ = Type.imm (Size.in_bits size) in
  let exp = try abi arch arg_pos with
      exn -> Bil.unknown "unkown abi" typ in
  (* so far we assume, that [abi] returns expressions of word size,
     if this will ever change, then we need to extend abi function
     to return the size for us. *)
  let exp = (word_size >: size) exp in
  let var = Var.create (Sub.name sub ^ "_" ^ arg_name) typ in
  Arg.create ~intent:arg_intent var exp |>
  set_arg_attrs arg_attrs


let set_attr sub {attr_name; attr_args} =
  let set tag = Term.set_attr sub tag () in
  (* Term.set_attr sub Sub.alloc_size args in *)
  match attr_name with
  | "const"    -> set Sub.const
  | "pure"     -> set Sub.pure
  | "malloc"   -> set Sub.malloc
  | "noreturn" -> set Sub.noreturn
  | "returns_twice" -> set Sub.returns_twice
  | "nothrow"  -> set Sub.nothrow
  | s -> sub

let set_attr sub ({attr_name=name} as attr) =
  try set_attr sub attr with
  | Attr_type (exp,got) ->
    eprintf "%s: wrong type for attribute %s - expected %s, got %S\n"
      (Sub.name sub) name exp got;
    sub
  | Attr_index (max,ind) ->
    eprintf "%s: wrong index for attribute %s - %d < %d\n"
      (Sub.name sub) name ind max;
    sub
  | Attr_arity exp ->
    eprintf "%s: wrong arity for attribute %s - expected %s\n"
      (Sub.name sub) name exp;
    sub


let set_attrs attrs sub =
  List.fold attrs ~init:sub ~f:set_attr

let fill_args arch fns program =
  Term.map sub_t program ~f:(fun sub ->
      match Map.find fns (Sub.name sub) with
      | None -> sub
      | Some {args; attrs} ->
        List.fold args ~init:sub ~f:(fun sub arg ->
            Term.append arg_t sub (term_of_arg arch sub arg)) |>
        set_attrs attrs)

let main bundle options proj =
  let prog = Project.program proj in
  let arch = Project.arch proj in
  let args = protos_of_bundle bundle in
  let args = match options.use_header with
    | Some file -> merge_args args (protos_of_file file)
    | None -> args in
  fill_args arch args prog |>
  Project.with_program proj

module Cmdline = struct
  include Cmdliner

  let man = [
    `S "DESCRIPTION";
    `P "Use API definition to annotate subroutines. The API is
    specified using C syntax, extended with GNU attributes. The plugin
    has an embedded knowledge of a big subset of POSIX standard, but
    new interfaces can be added.";
    `P "The plugin will insert arg terms, based on the C function declarations
    and definitions. Known gnu attributes will be mapped to
    corresponding $(b,Sub) attributes, e.g., a subroutine annotated with
    $(b,__attribute__((noreturn))) will have IR attribute
    $(b,Sub.noreturn).";
    `S "NOTES";
    `P "A file with API shouldn't contain preprocessor directives, as
    preproccessing is not run. If it has, then consider running cpp
    manually. Also, all types and structures must be defined. An
    undefined type will result in a parsing error."
  ]

  let add_headers : string list Term.t =
    let doc =
      "Add C header with function prototypes to the plugin database, \
       which will be used by default if file_header is not specified." in
    Arg.(value & opt (list file) [] & info ["add"] ~doc)

  let file_header : string option Term.t =
    let doc =
      "Use specified API. The file is not added
       to the plugin database of headers." in
    Arg.(value & opt (some string) None & info ["file"] ~doc)

  let process_args add_headers use_header = {add_headers; use_header}

  let parse argv =
    let info = Term.info ~doc ~man name in
    let spec = Term.(pure process_args $add_headers $file_header) in
    match Term.eval ~argv (spec,info) with
    | `Ok res -> res
    | `Error err -> exit 1
    | `Version | `Help -> exit 0
end

let ignore_protos : fn_proto String.Map.t -> unit = ignore

let add_headers bundle file =
  let name = "api/" ^ Filename.basename file in
  try
    protos_of_file file |> ignore_protos;
    Bundle.insert_file ~name bundle (Uri.of_string file)
  with
  | Parsing.Parse_error ->
    printf "Could not add header file: parse error."; exit 1

let () =
  let bundle = main_bundle () in
  let options = Cmdline.parse argv in
  match options.add_headers with
  | [] ->  Project.register_pass ~autorun:true (main bundle options)
  | headers -> List.iter headers ~f:(add_headers bundle);
    exit 0