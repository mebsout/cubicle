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

exception EmptyHeap

module type OrderType = sig
  type t

  val compare : t -> t -> int
end

module type S = sig
  type t
  type elem 

  val empty : t
  val pop : t -> elem * t
  val add : t -> elem list -> t
  val elements : t -> elem list
  val length : t -> int
end

module Make ( X : OrderType ) : S with type elem = X.t
