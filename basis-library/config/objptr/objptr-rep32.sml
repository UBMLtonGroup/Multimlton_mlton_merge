(* Copyright (C) 1999-2006 Henry Cejtin, Matthew Fluet, Suresh
 *    Jagannathan, and Stephen Weeks.
 *
 * MLton is released under a BSD-style license.
 * See the file MLton-LICENSE for details.
 *)

structure ObjptrInt = Int32
structure ObjptrWord = Word32

functor ObjptrInt_ChooseIntN (A: CHOOSE_INTN_ARG) :
   sig val f : ObjptrInt.int A.t end = 
   ChooseIntN_Int32 (A)
functor ObjptrWord_ChooseWordN (A: CHOOSE_WORDN_ARG) :
   sig val f : ObjptrWord.word A.t end = 
   ChooseWordN_Word32 (A)
