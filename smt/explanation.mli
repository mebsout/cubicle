(**************************************************************************)
(*                                                                        *)
(*                              Cubicle                                   *)
(*                                                                        *)
(*                       Copyright (C) 2011-2014                          *)
(*                                                                        *)
(*                  Sylvain Conchon and Alain Mebsout                     *)
(*                       Universite Paris-Sud 11                          *)
(*                                                                        *)
(*                                                                        *)
(*  This file is distributed under the terms of the Apache Software       *)
(*  License version 2.0                                                   *)
(*                                                                        *)
(**************************************************************************)

type t

type exp

val empty : t

val singleton : Solver_types.atom -> t

val union : t -> t -> t

val merge : t -> t -> t

val iter_atoms : (Solver_types.atom -> unit)  -> t -> unit

val fold_atoms : (Solver_types.atom -> 'a -> 'a )  -> t -> 'a -> 'a

val fresh_exp : unit -> int

val remove_fresh : int -> t -> t option

val add_fresh : int -> t -> t

val print : Format.formatter -> t -> unit
