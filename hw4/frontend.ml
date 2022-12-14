open Ll
open Llutil
open Ast

(* instruction streams ------------------------------------------------------ *)

(* As in the last project, we'll be working with a flattened representation
   of LLVMlite programs to make emitting code easier. This version
   additionally makes it possible to emit elements will be gathered up and
   "hoisted" to specific parts of the constructed CFG
   - G of gid * Ll.gdecl: allows you to output global definitions in the middle
     of the instruction stream. You will find this useful for compiling string
     literals
   - E of uid * insn: allows you to emit an instruction that will be moved up
     to the entry block of the current function. This will be useful for 
     compiling local variable declarations
*)

type elt = 
  | L of Ll.lbl             (* block labels *)
  | I of uid * Ll.insn      (* instruction *)
  | T of Ll.terminator      (* block terminators *)
  | G of gid * Ll.gdecl     (* hoisted globals (usually strings) *)
  | E of uid * Ll.insn      (* hoisted entry block instructions *)

type stream = elt list
let ( >@ ) x y = y @ x
let ( >:: ) x y = y :: x
let lift : (uid * insn) list -> stream = List.rev_map (fun (x,i) -> I (x,i))

(* Build a CFG and collection of global variable definitions from a stream *)
let cfg_of_stream (code:stream) : Ll.cfg * (Ll.gid * Ll.gdecl) list  =
    let gs, einsns, insns, term_opt, blks = List.fold_left
      (fun (gs, einsns, insns, term_opt, blks) e ->
        match e with
        | L l ->
           begin match term_opt with
           | None -> 
              if (List.length insns) = 0 then (gs, einsns, [], None, blks)
              else failwith @@ Printf.sprintf "build_cfg: block labeled %s has\
                                               no terminator" l
           | Some term ->
              (gs, einsns, [], None, (l, {insns; term})::blks)
           end
        | T t  -> (gs, einsns, [], Some (Llutil.Parsing.gensym "tmn", t), blks)
        | I (uid,insn)  -> (gs, einsns, (uid,insn)::insns, term_opt, blks)
        | G (gid,gdecl) ->  ((gid,gdecl)::gs, einsns, insns, term_opt, blks)
        | E (uid,i) -> (gs, (uid, i)::einsns, insns, term_opt, blks)
      ) ([], [], [], None, []) code
    in
    match term_opt with
    | None -> failwith "build_cfg: entry block has no terminator" 
    | Some term -> 
       let insns = einsns @ insns in
       ({insns; term}, blks), gs


(* compilation contexts ----------------------------------------------------- *)

(* To compile OAT variables, we maintain a mapping of source identifiers to the
   corresponding LLVMlite operands. Bindings are added for global OAT variables
   and local variables that are in scope. *)

module Ctxt = struct

  type t = (Ast.id * (Ll.ty * Ll.operand)) list
  let empty = []

  (* Add a binding to the context *)
  let add (c:t) (id:id) (bnd:Ll.ty * Ll.operand) : t = (id,bnd)::c

  (* Lookup a binding in the context *)
  let lookup (id:Ast.id) (c:t) : Ll.ty * Ll.operand =
    try List.assoc id c with Not_found -> failwith ("Lookup error: "^id)

  (* Lookup a function, fail otherwise *)
  let lookup_function (id:Ast.id) (c:t) : Ll.ty * Ll.operand =
    match List.assoc id c with
    | Ptr (Fun (args, ret)), g -> Ptr (Fun (args, ret)), g
    | _ -> failwith @@ id ^ " not bound to a function"

  let lookup_function_option (id:Ast.id) (c:t) : (Ll.ty * Ll.operand) option =
    try Some (lookup_function id c) with _ -> None
  
end

(* compiling OAT types ------------------------------------------------------ *)

(* The mapping of source types onto LLVMlite is straightforward. Booleans and ints
   are represented as the corresponding integer types. OAT strings are
   pointers to bytes (I8). Arrays are the most interesting type: they are
   represented as pointers to structs where the first component is the number
   of elements in the following array.

   The trickiest part of this project will be satisfying LLVM's rudimentary type
   system. Recall that global arrays in LLVMlite need to be declared with their
   length in the type to statically allocate the right amount of memory. The 
   global strings and arrays you emit will therefore have a more specific type
   annotation than the output of cmp_rty. You will have to carefully bitcast
   gids to satisfy the LLVM type checker.
*)

let rec cmp_ty : Ast.ty -> Ll.ty = function
  | Ast.TBool  -> I1
  | Ast.TInt   -> I64
  | Ast.TRef r -> Ptr (cmp_rty r)

and cmp_rty : Ast.rty -> Ll.ty = function
  | Ast.RString  -> I8
  | Ast.RArray u -> Struct [I64; Array(0, cmp_ty u)]
  | Ast.RFun (ts, t) -> 
      let args, ret = cmp_fty (ts, t) in
      Fun (args, ret)

and cmp_ret_ty : Ast.ret_ty -> Ll.ty = function
  | Ast.RetVoid  -> Void
  | Ast.RetVal t -> cmp_ty t

and cmp_fty (ts, r) : Ll.fty =
  List.map cmp_ty ts, cmp_ret_ty r


let typ_of_binop : Ast.binop -> Ast.ty * Ast.ty * Ast.ty = function
  | Add | Mul | Sub | Shl | Shr | Sar | IAnd | IOr -> (TInt, TInt, TInt)
  | Eq | Neq | Lt | Lte | Gt | Gte -> (TInt, TInt, TBool)
  | And | Or -> (TBool, TBool, TBool)

let typ_of_unop : Ast.unop -> Ast.ty * Ast.ty = function
  | Neg | Bitnot -> (TInt, TInt)
  | Lognot       -> (TBool, TBool)

(* Compiler Invariants

   The LLVM IR type of a variable (whether global or local) that stores an Oat
   array value (or any other reference type, like "string") will always be a
   double pointer.  In general, any Oat variable of Oat-type t will be
   represented by an LLVM IR value of type Ptr (cmp_ty t).  So the Oat variable
   x : int will be represented by an LLVM IR value of type i64*, y : string will
   be represented by a value of type i8**, and arr : int[] will be represented
   by a value of type {i64, [0 x i64]}**.  Whether the LLVM IR type is a
   "single" or "double" pointer depends on whether t is a reference type.

   We can think of the compiler as paying careful attention to whether a piece
   of Oat syntax denotes the "value" of an expression or a pointer to the
   "storage space associated with it".  This is the distinction between an
   "expression" and the "left-hand-side" of an assignment statement.  Compiling
   an Oat variable identifier as an expression ("value") does the load, so
   cmp_exp called on an Oat variable of type t returns (code that) generates a
   LLVM IR value of type cmp_ty t.  Compiling an identifier as a left-hand-side
   does not do the load, so cmp_lhs called on an Oat variable of type t returns
   and operand of type (cmp_ty t)*.  Extending these invariants to account for
   array accesses: the assignment e1[e2] = e3; treats e1[e2] as a
   left-hand-side, so we compile it as follows: compile e1 as an expression to
   obtain an array value (which is of pointer of type {i64, [0 x s]}* ).
   compile e2 as an expression to obtain an operand of type i64, generate code
   that uses getelementptr to compute the offset from the array value, which is
   a pointer to the "storage space associated with e1[e2]".

   On the other hand, compiling e1[e2] as an expression (to obtain the value of
   the array), we can simply compile e1[e2] as a left-hand-side and then do the
   load.  So cmp_exp and cmp_lhs are mutually recursive.  [[Actually, as I am
   writing this, I think it could make sense to factor the Oat grammar in this
   way, which would make things clearer, I may do that for next time around.]]

 
   Consider globals7.oat

   /--------------- globals7.oat ------------------ 
   global arr = int[] null;

   int foo() { 
     var x = new int[3]; 
     arr = x; 
     x[2] = 3; 
     return arr[2]; 
   }
   /------------------------------------------------

   The translation (given by cmp_ty) of the type int[] is {i64, [0 x i64}* so
   the corresponding LLVM IR declaration will look like:

   @arr = global { i64, [0 x i64] }* null

   This means that the type of the LLVM IR identifier @arr is {i64, [0 x i64]}**
   which is consistent with the type of a locally-declared array variable.

   The local variable x would be allocated and initialized by (something like)
   the following code snippet.  Here %_x7 is the LLVM IR uid containing the
   pointer to the "storage space" for the Oat variable x.

   %_x7 = alloca { i64, [0 x i64] }*                              ;; (1)
   %_raw_array5 = call i64*  @oat_alloc_array(i64 3)              ;; (2)
   %_array6 = bitcast i64* %_raw_array5 to { i64, [0 x i64] }*    ;; (3)
   store { i64, [0 x i64]}* %_array6, { i64, [0 x i64] }** %_x7   ;; (4)

   (1) note that alloca uses cmp_ty (int[]) to find the type, so %_x7 has 
       the same type as @arr 

   (2) @oat_alloc_array allocates len+1 i64's 

   (3) we have to bitcast the result of @oat_alloc_array so we can store it
        in %_x7 

   (4) stores the resulting array value (itself a pointer) into %_x7 

  The assignment arr = x; gets compiled to (something like):

  %_x8 = load { i64, [0 x i64] }*, { i64, [0 x i64] }** %_x7     ;; (5)
  store {i64, [0 x i64] }* %_x8, { i64, [0 x i64] }** @arr       ;; (6)

  (5) load the array value (a pointer) that is stored in the address pointed 
      to by %_x7 

  (6) store the array value (a pointer) into @arr 

  The assignment x[2] = 3; gets compiled to (something like):

  %_x9 = load { i64, [0 x i64] }*, { i64, [0 x i64] }** %_x7      ;; (7)
  %_index_ptr11 = getelementptr { i64, [0 x  i64] }, 
                  { i64, [0 x i64] }* %_x9, i32 0, i32 1, i32 2   ;; (8)
  store i64 3, i64* %_index_ptr11                                 ;; (9)

  (7) as above, load the array value that is stored %_x7 

  (8) calculate the offset from the array using GEP

  (9) store 3 into the array

  Finally, return arr[2]; gets compiled to (something like) the following.
  Note that the way arr is treated is identical to x.  (Once we set up the
  translation, there is no difference between Oat globals and locals, except
  how their storage space is initially allocated.)

  %_arr12 = load { i64, [0 x i64] }*, { i64, [0 x i64] }** @arr    ;; (10)
  %_index_ptr14 = getelementptr { i64, [0 x i64] },                
                 { i64, [0 x i64] }* %_arr12, i32 0, i32 1, i32 2  ;; (11)
  %_index15 = load i64, i64* %_index_ptr14                         ;; (12)
  ret i64 %_index15

  (10) just like for %_x9, load the array value that is stored in @arr 

  (11)  calculate the array index offset

  (12) load the array value at the index 

*)

(* Global initialized arrays:

  There is another wrinkle: To compile global initialized arrays like in the
  globals4.oat, it is helpful to do a bitcast once at the global scope to
  convert the "precise type" required by the LLVM initializer to the actual
  translation type (which sets the array length to 0).  So for globals4.oat,
  the arr global would compile to (something like):

  @arr = global { i64, [0 x i64] }* bitcast 
           ({ i64, [4 x i64] }* @_global_arr5 to { i64, [0 x i64] }* ) 
  @_global_arr5 = global { i64, [4 x i64] } 
                  { i64 4, [4 x i64] [ i64 1, i64 2, i64 3, i64 4 ] }

*) 



(* Some useful helper functions *)

(* Generate a fresh temporary identifier. Since OAT identifiers cannot begin
   with an underscore, these should not clash with any source variables *)
let gensym : string -> string =
  let c = ref 0 in
  fun (s:string) -> incr c; Printf.sprintf "_%s%d" s (!c)

(* Amount of space an Oat type takes when stored in the satck, in bytes.  
   Note that since structured values are manipulated by reference, all
   Oat values take 8 bytes on the stack.
*)
let size_oat_ty (t : Ast.ty) = 8L

(* Generate code to allocate a zero-initialized array of source type TRef (RArray t) of the
   given size. Note "size" is an operand whose value can be computed at
   runtime *)
let oat_alloc_array (t:Ast.ty) (size:Ll.operand) : Ll.ty * operand * stream =
  let ans_id, arr_id = gensym "array", gensym "raw_array" in
  let ans_ty = cmp_ty @@ TRef (RArray t) in
  let arr_ty = Ptr I64 in
  ans_ty, Id ans_id, lift
    [ arr_id, Call(arr_ty, Gid "oat_alloc_array", [I64, size])
    ; ans_id, Bitcast(arr_ty, Id arr_id, ans_ty) ]

(* Compiles an expression exp in context c, outputting the Ll operand that will
   recieve the value of the expression, and the stream of instructions
   implementing the expression. 

   Tips:
   - use the provided cmp_ty function!

   - string literals (CStr s) should be hoisted. You'll need to make sure
     either that the resulting gid has type (Ptr I8), or, if the gid has type
     [n x i8] (where n is the length of the string), convert the gid to a 
     (Ptr I8), e.g., by using getelementptr.

   - use the provided "oat_alloc_array" function to implement literal arrays
     (CArr) and the (NewArr) expressions

*)
let ret_ty_binop (b:binop) : (Ll.ty) =
  begin match b with
    | Add | Sub | Mul | Shl | Sar | Shr | IAnd | IOr -> I64
    | Eq | Neq | Lt | Lte | Gt | Gte | And | Or -> I1
end


let rec cmp_exp (c:Ctxt.t) (exp:Ast.exp node) : Ll.ty * Ll.operand * stream =
  begin match exp.elt with
    | Id id -> 
      let uid = gensym "uid" in
      let ty, op = try Ctxt.lookup id c with Not_found -> failwith "id lookup error" in
      (ty, Id uid, [I (uid, Load (Ptr ty, op))])
    | CInt i -> (I64, Const i, [])

    | CStr s -> 
      let gid = gensym "str" in
      let uid = gensym "lstr" in
      let ty = cmp_ty (TRef (RString)) in
      let ll_ty = Array(String.length s + 1, I8) in
      let gdecl_ = (ll_ty, GString s) in
      let stream_ = [G (gid, gdecl_)] @ [I (uid, Bitcast(Ptr ll_ty, Gid gid, Ptr I8))] in
      (ty, Id uid, stream_)

    | CNull null -> (cmp_ty (TRef null), Null, [])
    | CBool b -> (I1, Const (if b=true then 1L else 0L), [])

    | Index (arr,ind) -> 
      let arr_ty, arr_op, arr_str = cmp_exp c arr in
      let ind_ty, ind_op, ind_str = cmp_exp c ind in
      begin match arr_ty with
        | Ptr(Struct [_; Array(_, ty)]) ->
          let id = gensym "gep" in
          let ptr = gensym "ptr" in
          (ty, Id id, [I (id, Load (Ptr (ty), Id ptr))] @ [I (ptr, Gep (arr_ty, arr_op, [Const 0L; Const 1L; ind_op]))] @ ind_str @ arr_str)
        | ty -> failwith ("Illegal array type in Index: "^(string_of_ty ty))
      end
      
    | Call (e,el) -> cmp_call c e el

    | CArr (arr,l) ->
      let arr_ty, arr_op, arr_str = oat_alloc_array arr (Const (Int64.of_int (List.length l))) in
      let cmp_list = List.map (fun x -> cmp_exp c x) l in
      let l_str = List.flatten (List.map (fun (_,_,x) -> x) cmp_list) in
      let stream_ = ref [] in
      for i=0 to (List.length cmp_list - 1) do 
        let ty, op, str = List.nth cmp_list i in
        let guid = gensym "gep" in
        let gep = Gep (arr_ty, arr_op, [Const 0L; Const 1L; Const (Int64.of_int i)]) in
        let uid = gensym "store" in 
        let store = Store (ty, op, Id guid) in
        stream_ := lift [guid, gep; uid, store] @ !stream_ 
      done;
      (arr_ty, arr_op, !stream_ @ arr_str @ l_str)

    | NewArr (arr, e) ->  
      let e_ty, e_op, e_str = cmp_exp c e in
      let arr_ty, arr_op, arr_str = oat_alloc_array arr e_op in
      (arr_ty, arr_op, arr_str @ e_str)

    | Bop (b,e1,e2) -> 
      let e1_ty, e1_op, e1_str = cmp_exp c e1 in
      let e2_ty, e2_op, e2_str = cmp_exp c e2 in
      let ret_ty = ret_ty_binop b in
      let uid = gensym "binop" in
      let stream_ = 
        begin match b with
          | Add -> [I (uid, (Binop (Add, I64, e1_op, e2_op)))]
          | Sub -> [I (uid, (Binop (Sub, I64, e1_op, e2_op)))]
          | Mul -> [I (uid, (Binop (Mul, I64, e1_op, e2_op)))]
          | Eq -> [I (uid, (Icmp (Eq, I64, e1_op, e2_op)))]
          | Neq -> [I (uid, (Icmp (Ne, I64, e1_op, e2_op)))]
          | Lt -> [I (uid, (Icmp (Slt, I64, e1_op, e2_op)))]
          | Lte -> [I (uid, (Icmp (Sle, I64, e1_op, e2_op)))]
          | Gt -> [I (uid, (Icmp (Sgt, I64, e1_op, e2_op)))]
          | Gte -> [I (uid, (Icmp (Sge, I64, e1_op, e2_op)))]
          | And -> [I (uid, (Binop (And, I1, e1_op, e2_op)))]
          | Or -> [I (uid, (Binop (Or, I1, e1_op, e2_op)))]
          | IAnd -> [I (uid, (Binop (And, I64, e1_op, e2_op)))]
          | IOr -> [I (uid, (Binop (Or, I64, e1_op, e2_op)))]
          | Shl -> [I (uid, (Binop (Shl, I64, e1_op, e2_op)))]
          | Shr -> [I (uid, (Binop (Lshr, I64, e1_op, e2_op)))]
          | Sar -> [I (uid, (Binop (Ashr, I64, e1_op, e2_op)))]
      end in
      (ret_ty, Id uid, stream_ @ e2_str @ e1_str)
    | Uop (u, e) -> 
      let e_ty, e_op, e_str = cmp_exp c e in
      let uid = gensym "uop" in
      let stream_ = 
        begin match u with
          | Neg -> [I (uid, (Binop (Mul, I64, Const (-1L), e_op)))]
          | Bitnot -> [I (uid, (Binop (Xor, I64, Const (-1L), e_op)))]
          | Lognot -> [I (uid, (Icmp (Eq, I1, Const 0L, e_op)))]
      end in
      (e_ty, Id uid, stream_ @ e_str)
end

(*helper for cmp_exp and cmp_stmt*)
and cmp_call (c:Ctxt.t) (exp:exp node) (el:exp node list) : Ll.ty * Ll.operand * stream = 
  let id =
    begin match exp.elt with
      | Id (id_) -> id_
      | _ -> failwith "illegal"
  end in 
  let ptr, op = Ctxt.lookup id c in
  begin match ptr with
    | Ptr Fun(list_ty, ret_ty) ->
      let list = ref [] in
      let stream = ref [] in
      for i=0 to (List.length el - 1) do
        let curr = try List.nth el i with Not_found -> failwith "What" in
        let ty_, op_, stream_ = try cmp_exp c curr with Not_found -> failwith "Exp" in
        list := !list @ [(ty_,op_)];
        stream := stream_ @ !stream;
      done;
      let id = gensym "call" in
      (ret_ty, Id id, [I (id, Call(ret_ty, op, !list))] @ !stream)
    | _ -> failwith "illegal"
end

(* Compile a statement in context c with return typ rt. Return a new context, 
   possibly extended with new local bindings, and the instruction stream
   implementing the statement.

   Left-hand-sides of assignment statements must either be OAT identifiers,
   or an index into some arbitrary expression of array type. Otherwise, the
   program is not well-formed and your compiler may throw an error.

   Tips:
   - for local variable declarations, you will need to emit Allocas in the
     entry block of the current function using the E() constructor.

   - don't forget to add a bindings to the context for local variable 
     declarations
   
   - you can avoid some work by translating For loops to the corresponding
     While loop, building the AST and recursively calling cmp_stmt

   - you might find it helpful to reuse the code you wrote for the Call
     expression to implement the SCall statement

   - compiling the left-hand-side of an assignment is almost exactly like
     compiling the Id or Index expression. Instead of loading the resulting
     pointer, you just need to store to it!

 *)



let rec cmp_stmt (c:Ctxt.t) (rt:Ll.ty) (stmt:Ast.stmt node) : Ctxt.t * stream =
  begin match stmt.elt with
    | Assn (lhs,e) -> 
      let lhs_ = lhs.elt in
      let e_ty, e_op, e_str = cmp_exp c e in
      begin match lhs_ with
        | Id (id) -> 
          let ty, op = Ctxt.lookup id c in
          let id_ = gensym "assign" in
          (c, [I (id_, Store (e_ty, e_op, op))] @ e_str)
        | Index (arr, ind) -> 
          let arr_ty, arr_op, arr_str = cmp_exp c arr in
          let ind_ty, ind_op, ind_str = cmp_exp c ind in
          begin match arr_ty with
           | Ptr (Struct [_; Array(_,ty)]) -> 
            let uid = gensym "" in
            (c, [I (uid, Store (e_ty, e_op, Id uid))] @ [I (uid, Gep (arr_ty, arr_op, [Const 0L; Const 1L; ind_op]))] @ ind_str @ arr_str @ e_str)
           | _ -> failwith "illegal"
        end
        | _ -> failwith "illegal"
    end

    | Decl v -> 
      let id, e = v in
      let mangled = gensym id in
      let e_ty, e_op, e_str = cmp_exp c e in
      (Ctxt.add c id (e_ty, Id mangled), [I (mangled, Store (e_ty, e_op, Id mangled))] @ [E (mangled, Alloca e_ty)] @ e_str)

    | Ret r -> 
      begin match r with
        | None -> (c, [T (Ret(Void, None))])
        | Some e -> 
          let e_ty, e_op, e_str = cmp_exp c e in
          (c, [T (Ret(rt, Some e_op))] @ e_str)
    end
    | SCall (e,el) -> 
      let _, _, stream = cmp_call c e el in
      (c, stream)
    | If (e,s1,s2) -> 
      let e_ty, e_op, e_str = cmp_exp c e in
      let _, then_ = cmp_block c rt s1 in
      let _, else_ = cmp_block c rt s2 in
      let then_lbl = gensym "then" in
      let else_lbl = gensym "else" in
      let end_lbl = gensym "end" in
      let cbr_str = [T (Cbr (e_op, then_lbl, else_lbl))] in
      let end_str = [T (Br end_lbl)] in
      let stream_ = [L (end_lbl)] @ end_str @ else_ @ [L (else_lbl)] @ end_str @ then_ @ [L (then_lbl)] @ cbr_str @ e_str  in
      (c, stream_)
    | For (vdecls, e_opt, s_opt, bl) -> 
      let e_opt = 
        begin match e_opt with
         | None -> no_loc (CBool true)
         | Some s -> s
      end in
      let s_opt =
        begin match s_opt with
          | None -> []
          | Some s -> [s]
      end in
      let initv = List.map (fun x -> no_loc (Decl x)) vdecls in
      let c, v_str = cmp_block c rt initv in
      let c, stream_ = cmp_stmt c rt {elt = (While (e_opt, (bl @ s_opt))); loc = stmt.loc} in 
      (c, stream_ @ v_str)
    | While (e, bl) -> 
      let e_ty, e_op, e_str = cmp_exp c e in
      let _, bl_str = cmp_block c rt bl in
      let is_true = gensym "is_true" in
      let do_smth = gensym "do_smth" in
      let end_lbl = gensym "end" in
      let start_str = [T (Br (is_true))] in
      let while_str = e_str @ [L is_true] in
      let br_str = [T (Cbr (e_op, do_smth, end_lbl))] in
      let do_str = [T (Br (is_true))] @ bl_str @ [L do_smth] in
      let end_str = [L end_lbl] in
      (c, end_str @ do_str @ br_str @ while_str @ start_str)
end

(* Compile a series of statements *)
and cmp_block (c:Ctxt.t) (rt:Ll.ty) (stmts:Ast.block) : Ctxt.t * stream =
  List.fold_left (fun (c, code) s -> 
      let c, stmt_code = cmp_stmt c rt s in
      c, code >@ stmt_code
    ) (c,[]) stmts



(* Adds each function identifer to the context at an
   appropriately translated type.  

   NOTE: The Gid of a function is just its source name
*)
let cmp_function_ctxt (c:Ctxt.t) (p:Ast.prog) : Ctxt.t =
    List.fold_left (fun c -> function
      | Ast.Gfdecl { elt={ frtyp; fname; args } } ->
         let ft = TRef (RFun (List.map fst args, frtyp)) in
         Ctxt.add c fname (cmp_ty ft, Gid fname)
      | _ -> c
    ) c p 

(* Populate a context with bindings for global variables 
   mapping OAT identifiers to LLVMlite gids and their types.

   Only a small subset of OAT expressions can be used as global initializers
   in well-formed programs. (The constructors starting with C). 
*)
let cmp_global_ctxt (c:Ctxt.t) (p:Ast.prog) : Ctxt.t =
  List.fold_left (fun c -> function
    | Gvdecl {elt={name;init}} ->
      let vt = 
        begin match init.elt with
          | CInt i -> cmp_ty TInt
          | CStr s -> cmp_ty (TRef RString)
          | CNull null -> cmp_ty (TRef (null))
          | CBool b -> cmp_ty TBool
          | CArr (ty, elems) -> cmp_ty (TRef (RArray ty))
          | _ -> failwith "not a global initializer"
      end in
      Ctxt.add c name (vt, Gid name)
    | _ -> c
  ) c p

(* Compile a function declaration in global context c. Return the LLVMlite cfg
   and a list of global declarations containing the string literals appearing
   in the function.

   You will need to
   1. Allocate stack space for the function parameters using Alloca
   2. Store the function arguments in their corresponding alloca'd stack slot
   3. Extend the context with bindings for function variables
   4. Compile the body of the function using cmp_block
   5. Use cfg_of_stream to produce a LLVMlite cfg from 
 *)

 
let cmp_fdecl (c:Ctxt.t) (f:Ast.fdecl node) : Ll.fdecl * (Ll.gid * Ll.gdecl) list =
  let foldfunc (c_, args_str_, f_ty_, f_param_) (arg_i_ty, arg_i_id) = begin
    let ll_arg_id = gensym arg_i_id in
    let ll_alloc_id = gensym arg_i_id in
    let ll_ty = cmp_ty arg_i_ty in
    let c_new = Ctxt.add c_ arg_i_id (ll_ty, Id ll_alloc_id) in
    let alloca_elt = E(ll_alloc_id, Alloca ll_ty) in
    let store_elt = I(gensym "store_uid", Store(ll_ty, Id ll_arg_id, Id ll_alloc_id)) in
    let args_str_new = args_str_ @ [store_elt; alloca_elt] in
    let f_ty_new = ((fst f_ty_) @ [ll_ty], snd f_ty_) in
    let f_param_new = f_param_ @ [ll_arg_id] in
    (c_new, args_str_new, f_ty_new, f_param_new)
  end in
  let f_rty = f.elt.frtyp in
  let args = f.elt.args in
  let body = f.elt.body in
  let ret_ty = cmp_ret_ty f_rty in
  let (c_, args_str, f_ty, f_param) = List.fold_left (foldfunc) (c, [], ([], ret_ty), []) args in
  let _, block_str = cmp_block c_ ret_ty body in
  let stream_ = block_str @ args_str in
  let f_cfg, gdecls_list = cfg_of_stream stream_ in
  let fdecl = {f_ty = f_ty; f_param = f_param; f_cfg = f_cfg} in
  (fdecl, gdecls_list)

  

(* Compile a global initializer, returning the resulting LLVMlite global
   declaration, and a list of additional global declarations.

   Tips:
   - Only CNull, CBool, CInt, CStr, and CArr can appear as global initializers
     in well-formed OAT programs. Your compiler may throw an error for the other
     cases

   - OAT arrays are always handled via pointers. A global array of arrays will
     be an array of pointers to arrays emitted as additional global declarations.
*)

let rec cmp_gexp c (e:Ast.exp node) : Ll.gdecl * (Ll.gid * Ll.gdecl) list =
  begin match e.elt with
    | CInt i -> (I64, GInt i), []
    | CStr s -> 
      let gid = gensym "str" in
      let ret_ty = Array(String.length s + 1, I8) in
      let cast = GBitcast (Ptr ret_ty, GGid gid, Ptr I8) in
      (Ptr I8, cast), [gid, (ret_ty, GString s)]
    | CNull null -> (cmp_ty (TRef null), GNull), []
    | CBool b -> (I1, GInt (if b=true then 1L else 0L)), []
    | CArr (ty, l) ->
      let ll_ty = cmp_ty (TRef (RArray ty)) in
      let gid = gensym "garr" in
      let ty_ = Array(List.length l, cmp_ty ty) in
      let cmp_list = List.map (fun x -> cmp_gexp c x) l in
      let ginit = List.map fst cmp_list in
      let cast = GBitcast (Ptr (Struct [I64; ty_]), GGid gid, ll_ty) in
      (ll_ty, cast), [gid, (Struct [I64; ty_], GStruct [I64, GInt (Int64.of_int (List.length l)); ty_, GArray ginit])]
    | _ -> failwith "not a global initializer"
end

(* Oat internals function context ------------------------------------------- *)
let internals = [
    "oat_alloc_array",         Ll.Fun ([I64], Ptr I64)
  ]

(* Oat builtin function context --------------------------------------------- *)
let builtins =
  [ "array_of_string",  cmp_rty @@ RFun ([TRef RString], RetVal (TRef(RArray TInt)))
  ; "string_of_array",  cmp_rty @@ RFun ([TRef(RArray TInt)], RetVal (TRef RString))
  ; "length_of_string", cmp_rty @@ RFun ([TRef RString],  RetVal TInt)
  ; "string_of_int",    cmp_rty @@ RFun ([TInt],  RetVal (TRef RString))
  ; "string_cat",       cmp_rty @@ RFun ([TRef RString; TRef RString], RetVal (TRef RString))
  ; "print_string",     cmp_rty @@ RFun ([TRef RString],  RetVoid)
  ; "print_int",        cmp_rty @@ RFun ([TInt],  RetVoid)
  ; "print_bool",       cmp_rty @@ RFun ([TBool], RetVoid)
  ]

(* Compile a OAT program to LLVMlite *)
let cmp_prog (p:Ast.prog) : Ll.prog =
  (* add built-in functions to context *)
  let init_ctxt = 
    List.fold_left (fun c (i, t) -> Ctxt.add c i (Ll.Ptr t, Gid i))
      Ctxt.empty builtins
  in
  let fc = cmp_function_ctxt init_ctxt p in

  (* build global variable context *)
  let c = cmp_global_ctxt fc p in

  (* compile functions and global variables *)
  let fdecls, gdecls = 
    List.fold_right (fun d (fs, gs) ->
        match d with
        | Ast.Gvdecl { elt=gd } -> 
           let ll_gd, gs' = cmp_gexp c gd.init in
           (fs, (gd.name, ll_gd)::gs' @ gs)
        | Ast.Gfdecl fd ->
           let fdecl, gs' = cmp_fdecl c fd in
           (fd.elt.fname,fdecl)::fs, gs' @ gs
      ) p ([], [])
  in

  (* gather external declarations *)
  let edecls = internals @ builtins in
  { tdecls = []; gdecls; fdecls; edecls }