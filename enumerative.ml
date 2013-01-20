(**************************************************************************)
(*                                                                        *)
(*                                  Cubicle                               *)
(*             Combining model checking algorithms and SMT solvers        *)
(*                                                                        *)
(*                  Sylvain Conchon and Alain Mebsout                     *)
(*                  Universite Paris-Sud 11                               *)
(*                                                                        *)
(*  Copyright 2011. This file is distributed under the terms of the       *)
(*  Apache Software License version 2.0                                   *)
(*                                                                        *)
(**************************************************************************)

open Options
open Format
open Ast
open Cube

module H = Hstring

module HT = Hashtbl.Make (struct
  type t = term
  let equal x y = compare_term x y = 0
  let hash = hash_term
end)

module HI = Hashtbl.Make 
  (struct 
  type t = int 
  let equal = (=) 
  let hash x = x end)


type state = int array


type state_info = int HT.t

let equal_state a1 a2 =
  let n = Array.length a1 in
  let n2 = Array.length a2 in
  if n <> n2 then false
  else
    let res = ref true in
    let i = ref 0 in 
    while !res && !i < n  do
      res := a1.(!i) = a2.(!i);
      incr i
    done;
    !res

type st_req = int * op_comp * int

type st_action = 
  | St_ignore
  | St_assign of int * int 
  | St_ite of st_req list * st_action * st_action


type state_transistion = {
  st_reqs : st_req list;
  st_udnfs : st_req list list list;
  st_actions : st_action list;
  st_f : state -> state;
}


type env = {
  var_terms : STerm.t;
  nb_vars : int;
  perm_procs : (int * int) list list;
  first_proc : int;
  extra_proc : int;
  all_procs : Hstring.t list;
  proc_ids : int list;
  id_terms : int HT.t;
  id_true : int;
  id_false : int;
  st_trs : state_transistion list;
}

let empty_env = {
  var_terms = STerm.empty;
  nb_vars = 0;
  perm_procs = [];
  first_proc = 0;
  extra_proc = 0;
  all_procs = [];
  proc_ids = [];
  id_terms = HT.create 0;
  id_true = 0;
  id_false = 0;
  st_trs = [];
}


let explicit_states = HI.create 2_000_029
let global_env = ref empty_env


exception Found of term

(* inefficient but only used for debug *)
let id_to_term env id =
  try
    HT.iter (fun t i -> if id = i then raise (Found t)) env.id_terms;
    raise Not_found
  with Found t -> t
      

(* inefficient but only used for debug *)
let state_to_cube env st =
  let i = ref 0 in
  Array.fold_left (fun sa sti ->
    let sa = 
      if sti <> -1 then
	let t1 = id_to_term env !i in
	let t2 = id_to_term env sti in
	SAtom.add (Atom.Comp (t1, Eq, t2)) sa
      else sa
    in
    incr i; sa)
    SAtom.empty st

    

let all_constr_terms () =
  List.rev_map (fun x -> Elem (x, Constr)) (Smt.Type.all_constructors ())

let terms_of_procs =
  List.map (fun x -> Elem (x, Var))

let init_tables procs s =
  let var_terms = all_var_terms procs s in
  let proc_terms = terms_of_procs procs in (* constantes *)
  let constr_terms = all_constr_terms () in (* constantes *)
  let nb_vars = STerm.cardinal var_terms in
  let nb_procs = List.length proc_terms in
  let nb_consts = nb_procs + List.length constr_terms in
  let ht = HT.create (nb_vars + nb_consts) in
  let i = ref 0 in
  STerm.iter (fun t -> HT.add ht t !i; incr i) var_terms;
  let proc_ids = ref [] in
  let first_proc = !i in
  List.iter (fun t -> HT.add ht t !i; proc_ids := !i :: !proc_ids; incr i)
    proc_terms;
  (* add an extra process in case we need it : change this to statically compute
     how many extra processes are needed *)
  let ep = List.nth Ast.proc_vars nb_procs in
  let all_procs = procs @ [ep] in
  HT.add ht (Elem (ep, Var)) !i;
  let extra_proc = !i in
  incr i;

  List.iter (fun t -> HT.add ht t !i; incr i) constr_terms;
  let proc_ids = List.rev !proc_ids in
  let prem_procs = 
    List.filter (fun sigma ->
      List.exists (fun (x,y) -> x <> y) sigma
    ) (Cube.all_permutations proc_ids proc_ids) in
  if debug then
    HT.iter (fun t i -> eprintf "%a -> %d@." Pretty.print_term t i ) ht;
  let id_true = try HT.find ht (Elem (htrue, Constr)) with Not_found -> -2 in
  let id_false = try HT.find ht (Elem (hfalse, Constr)) with Not_found -> -2 in
  { var_terms = var_terms;
    nb_vars = nb_vars;
    perm_procs = prem_procs;
    first_proc = first_proc;
    extra_proc = extra_proc;
    all_procs = all_procs;
    proc_ids = proc_ids;
    id_terms = ht;
    id_true = id_true;
    id_false = id_false;
    st_trs = [];
  }


let apply_subst env st sigma =
  let st' = Array.copy st in
  for i = 0 to env.nb_vars - 1 do
    try let v = List.assoc st'.(i) sigma in st'.(i) <- v
    with Not_found -> ()
  done;
  st'

let normalize_state env st =
  let met = ref [] in
  let remaining = ref env.proc_ids in
  let sigma = ref [] in
  for i = 0 to Array.length st - 1 do
    let v = st.(i) in
    if !remaining <> [] then
      let r = List.hd !remaining in
      if env.first_proc <= v && v < env.extra_proc && 
        not (List.mem v !met) && v <> r then begin
          met := v :: !met;
          remaining := List.tl !remaining;
          sigma := (v,r) :: (r,v) :: !sigma
        end;
  done;
  apply_subst env st !sigma


let hash_state st =
  let h = ref 1 in
  (*let n = ref 2 in*)
  for i = 0 to Array.length st - 1 do
    let v = st.(i) in
    if v <> -1 then begin
      (*h := !h * (v + 2) + !n;*)
      (*n := 13 * !n + 7;*)
      h := (!h + 7) * (v + 11);
    end
  done;
  !h


let mkinit arg init args =
  match arg with
    | None -> init
    | Some z ->
        let abs_init = SAtom.filter (function
	  | Atom.Comp ((Elem (x, _) | Access (x,_,_)), _, _) ->
	      not (Smt.Symbol.has_infinite_type x)
	  | _ -> true) init in
	let abs_init = simplification_atoms SAtom.empty abs_init in
	let sa, cst = SAtom.partition (has_var z) abs_init in
	List.fold_left (fun acc h ->
	  SAtom.union (subst_atoms [z, h] sa) acc) cst args

let mkinit_s procs ({t_init = ia, init}) =
  let sa, (nargs, _) = proper_cube (mkinit ia init procs) in
  sa, nargs

let write_atom_to_state env st = function
  | Atom.Comp (t1, Eq, t2) ->
      st.(HT.find env.id_terms t1) <- HT.find env.id_terms t2
  | Atom.Comp (t1, Neq, Elem(_, Var)) ->
      (* Assume an extra process if a disequality is mentioned on
         type proc in init formula : change this to something more robust *)
      st.(HT.find env.id_terms t1) <- env.extra_proc
  | _ -> ()
  
let write_cube_to_state env st =
  SAtom.iter (write_atom_to_state env st)

let init_to_states env procs s =
  let nb = env.nb_vars in
  let st_init = Array.make nb (-1) in
  let init, _ = mkinit_s procs s in
  write_cube_to_state env st_init init;
  [hash_state st_init, st_init]

let atom_to_st_req env = function 
  | Atom.Comp (t1, op, t2) -> 
      HT.find env.id_terms t1, op, HT.find env.id_terms t2
  | _ -> assert false

let satom_to_st_req env sa =
  SAtom.fold (fun a acc -> 
    try (atom_to_st_req env a) :: acc
    with Not_found -> acc) sa []

let rec atom_to_st_action env = function 
  | Atom.Comp (t1, Eq, t2) -> 
    eprintf "%a <- %a@." Pretty.print_term t1 Pretty.print_term t2;
      St_assign (HT.find env.id_terms t1, HT.find env.id_terms t2)
  | Atom.Ite (sa, a1, a2) ->
      St_ite (satom_to_st_req env sa, atom_to_st_action env a1, 
	      atom_to_st_action env a2)
  | _ -> assert false

let satom_to_st_action env sa =
  SAtom.fold (fun a acc -> (atom_to_st_action env a) :: acc) sa []


type trivial_cond = Trivial of bool | Not_trivial

let trivial_cond env (i, op, v) =
  if env.first_proc <= i && i <= env.extra_proc && 
     env.first_proc <= v && v <= env.extra_proc then 
    match op with
      | Eq -> Trivial (i = v)
      | Neq -> Trivial (i <> v)
      | Le -> Trivial (i <= v)
      | Lt -> Trivial (i <> v)
  else Not_trivial

let trivial_conds env l =
  if l = [] then Trivial false
  else
    try
      List.iter (fun c -> match trivial_cond env c with
	| Trivial true -> ()
	| Trivial false -> raise Exit
	| Not_trivial -> raise Not_found
      ) l;
      Trivial true
    with 
      | Exit -> Trivial false
      | Not_found -> Not_trivial


let assigns_to_actions env sigma acc =
  List.fold_left 
    (fun acc (h, t) ->
      let nt = Elem (h, Glob) in
      let t = subst_term sigma t in
      try (St_assign (HT.find env.id_terms nt, HT.find env.id_terms t)) :: acc
      with Not_found -> acc
    ) acc

let nondets_to_actions env sigma acc =
  List.fold_left 
    (fun acc (h) ->
      let nt = Elem (h, Glob) in
      try (St_assign (HT.find env.id_terms nt, -1)) :: acc
      with Not_found -> acc
    ) acc

let update_to_actions procs sigma env acc
    {up_arr=a; up_arg=j; up_swts=swts} =
  let rec sd acc = function
    | [] -> assert false
    | [d] -> acc, d
    | s::r -> sd (s::acc) r in
  let swts, (d, t) = sd [] swts in
  (* assert (d = SAtom.singleton True); *)
  List.fold_left (fun acc i ->
    let sigma = (j,i)::sigma in
    let at = Access (a, i, Var) in
    let t = subst_term sigma t in
    let default =
      St_assign (HT.find env.id_terms at, HT.find env.id_terms t) in
    let ites = 
      List.fold_left (fun ites (sa, t) ->
	let sa = subst_atoms sigma sa in
	let t = subst_term sigma t in
	let sta = 
	  try St_assign (HT.find env.id_terms at, HT.find env.id_terms t)
	  with Not_found -> St_ignore
	in
	let conds = satom_to_st_req env sa in
	match trivial_conds env conds with
	  | Trivial true -> sta
	  | Trivial false -> ites
	  | Not_trivial -> St_ite (satom_to_st_req env sa, sta, ites)
      ) default swts
    in ites :: acc
  ) acc procs

let missing_reqs_to_actions acct =
  List.fold_left (fun acc -> function
    | (a, Eq, b) ->
        if List.exists
          (function St_assign (a', _) -> a = a' | _ -> false) acct
        then acc
        else (St_assign (a,b)) :: acc
    | _ -> acc) acct

exception Not_applicable

let value_in_state env st i =
  if i <> -1 && i < env.nb_vars then st.(i) else i

let check_req env st (i1, op, i2) =
  try
    let v1 = value_in_state env st i1 in
    let v2 = value_in_state env st i2 in
    v1 = -1 || v2 = -1 ||
	match op with
	  | Eq -> v1 = v2
	  | Neq -> v1 <> v2
	  | Le -> v1 <= v2
	  | Lt -> v1 < v2
  with Not_found -> true

let check_reqs env st = List.for_all (check_req env st)


let rec apply_action env st st' = function
  | St_ignore -> ()
  | St_assign (i1, i2) ->
    begin
      try
	let v2 = value_in_state env st i2 in
	st'.(i1) <- v2
      with Not_found -> ()
    end 
  | St_ite (reqs, a1, a2) ->
      if check_reqs env st reqs then apply_action env st st' a1
      else apply_action env st st' a2

let apply_actions env st acts =
  let st' = Array.copy st in
  List.iter (apply_action env st st') acts;
  st'


let rec print_action env fmt = function
  | St_ignore -> ()
  | St_assign (i, -1) -> 
      fprintf fmt "%a = ." Pretty.print_term (id_to_term env i)
  | St_assign (i, v) -> 
      fprintf fmt "%a" Pretty.print_atom 
	(Atom.Comp (id_to_term env i, Eq, id_to_term env v))
  | St_ite (l, a1, a2) ->
      fprintf fmt "ITE (";
      List.iter (fun (i, op, v) -> 
	eprintf "%a && " Pretty.print_atom 
	  (Atom.Comp (id_to_term env i, op, id_to_term env v))
      ) l;
      fprintf fmt ", %a , %a )" (print_action env) a1 (print_action env) a2


let print_transition_fun env name sigma { st_reqs = st_reqs;
                                          st_udnfs = st_udnfs;
                                          st_actions = st_actions } fmt =
  fprintf fmt "%a (%a)\n" Hstring.print name Pretty.print_subst sigma;
  fprintf fmt "requires { \n";
      List.iter (fun (i, op, v) -> 
	fprintf fmt "          %a\n" Pretty.print_atom 
	  (Atom.Comp (id_to_term env i, op, id_to_term env v))
      ) st_reqs;
      List.iter (fun dnf ->
	fprintf fmt "          ";
	List.iter (fun r ->
	  List.iter (fun (i, op, v) -> 
	    fprintf fmt "%a &&" Pretty.print_atom 
	      (Atom.Comp (id_to_term env i, op, id_to_term env v))
	  ) r;
	  fprintf fmt " || ";
	) dnf;
	fprintf fmt "\n";
      ) st_udnfs;
      fprintf fmt "}\n";
      fprintf fmt "actions { \n";
      List.iter (fun a -> 
	fprintf fmt "         %a\n" (print_action env) a;
      ) st_actions;
      fprintf fmt "}\n@."
  

let transitions_to_func_aux procs env reduce acc { tr_args = tr_args; 
		                                   tr_reqs = reqs; 
		                                   tr_name = name;
		                                   tr_ureq = ureqs;
		                                   tr_assigns = assigns; 
		                                   tr_upds = upds; 
		                                   tr_nondets = nondets } =
  (* let _, others = Forward.missing_args procs tr_args in *)
  if List.length tr_args > List.length procs then acc
  else 
    let d = all_permutations tr_args procs in
    (* do it even if no arguments *)
    let d = if d = [] then [[]] else d in
    List.fold_left (fun acc sigma ->
      let reqs = subst_atoms sigma reqs in
      let t_args_ef = 
	List.fold_left (fun acc p -> 
	  try (svar sigma p) :: acc
	  with Not_found -> p :: acc) [] tr_args in
      let udnfs = Forward.uguard_dnf sigma procs t_args_ef ureqs in
      let st_reqs = satom_to_st_req env reqs in
      let st_udnfs = List.map (List.map (satom_to_st_req env)) udnfs in
      let st_actions = assigns_to_actions env sigma [] assigns in
      let st_actions = nondets_to_actions env sigma st_actions nondets in
      let st_actions = List.fold_left 
	(update_to_actions procs sigma env)
	st_actions upds in
      let st_actions = missing_reqs_to_actions st_actions st_reqs in
      let f = fun st ->
	if not (check_reqs env st st_reqs) then raise Not_applicable;
	if not (List.for_all (List.exists (check_reqs env st)) st_udnfs)
	then raise Not_applicable;
	apply_actions env st st_actions
      in
      let st_tr = {
        st_reqs = st_reqs;
        st_udnfs = st_udnfs;
        st_actions = st_actions;
        st_f = f;
      } in
      if debug then print_transition_fun env name sigma st_tr err_formatter;
      reduce acc st_tr
    ) acc d


let transitions_to_func procs env =
  List.fold_left 
    (transitions_to_func_aux procs env (fun acc st_tr -> st_tr :: acc)) []


let neg_req env = function
  | a, Eq, b ->
      if b = env.id_true then a, Eq, env.id_false
      else if b = env.id_false then a, Eq, env.id_true
      else a, Neq, b
  | a, Neq, b -> a, Eq, b
  | a, Le, b -> b, Lt, a
  | a, Lt, b -> b, Le, a



let post st visited trs acc cpt_q =
  List.fold_left (fun acc st_tr ->
    try 
      let s = st_tr.st_f st in
      let hs = hash_state s in
      if HI.mem visited hs then acc else 
        (incr cpt_q; (hs, s) :: acc)
    with Not_applicable -> acc) acc trs



let check_cand env state cand = 
  not (List.for_all (fun l -> check_req env state (neg_req env l)) cand)


let forward s procs env l =
  global_env := env;
  let cpt_f = ref 0 in
  let cpt_q = ref 1 in
  let trs = env.st_trs in
  let rec forward_rec s procs trs = function
    | [] ->
        eprintf "Total forward nodes : %d@." !cpt_f
    | (hst, st) :: to_do ->
	decr cpt_q;
        if HI.mem explicit_states hst then
	  forward_rec s procs trs to_do
        else
	  let to_do = post st explicit_states trs to_do cpt_q in
	  incr cpt_f;
	  if debug && verbose > 1 then
            eprintf "%d : %a\n@." !cpt_f
              Pretty.print_cube (state_to_cube env st);
	  if not quiet && !cpt_f mod 1000 = 0 then
            eprintf "%d (%d)@." !cpt_f !cpt_q;
	  HI.add explicit_states hst st;
	  forward_rec s procs trs to_do
  in
  forward_rec s procs trs l

let search procs init =
  let procs = procs (*@ init.t_glob_proc*) in
  let env = init_tables procs init in
  let st_inits = init_to_states env procs init in
  if debug then 
    List.iter (fun (_, st) ->
      eprintf "init : %a\n@." Pretty.print_cube (state_to_cube env st))
      st_inits;
  let env = { env with st_trs = transitions_to_func procs env init.t_trans } in
  forward init procs env st_inits



let satom_to_cand env sa =
  SAtom.fold (fun a c -> match Atom.neg a with
    | Atom.Comp (t1, (Eq | Neq as op), t2) -> 
        (HT.find env.id_terms t1, op, HT.find env.id_terms t2) :: c
    | _ -> raise Not_found)
    sa []

exception Sustainable of t_system

let smallest_to_resist_on_trace ls =
  let env = !global_env in
  let cands =
    List.fold_left (fun acc p ->
      try 
        (List.map (fun s -> satom_to_cand env (snd s.t_unsafe), s) p) :: acc
      with Not_found -> acc
    ) [] ls in
  let cands = ref (List.rev cands) in
  if !cands = [] then []
  else
    try
      let cpt = ref 0 in
      HI.iter (fun _ st ->
        incr cpt;
        if not quiet && !cpt mod 1000 = 0 then eprintf ".@?";
        cands := List.filter (fun p -> 
          List.for_all (fun (c, _) -> check_cand env st c) p
        ) !cands;
        if !cands = [] then raise Exit;
      ) explicit_states;
      if not quiet then eprintf "@.";
      List.iter (function 
        | (_,s) :: _ -> raise (Sustainable s)
        | [] -> ()
      ) !cands;
      []
    with
      | Exit | Not_found -> 
          if not quiet then eprintf "@.";
          []
      | Sustainable s -> [s]
