open Assert
open Hellocaml

(* These tests are provided by you -- they will NOT be graded *)

(* You should also add additional test cases here to help you   *)
(* debug your program.                                          *)

let provided_tests : suite = [
  Test ("Student-Provided Tests For Problem 1-3", [
    ("case1", assert_eqf (fun () -> 42) prob3_ans );
    ("case2", assert_eqf (fun () -> 25) (prob3_case2 17) );
    ("case3", assert_eqf (fun () -> prob3_case3) 64);
  ]);

  Test ("Student-Provided Tests For Problem 5", [
    ("case1", assert_eqf (fun () -> run [] (compile e1)) 6L );
    ("case2", assert_eqf (fun () -> run ctxt2 (compile e2)) 3L);
    ("case3", assert_eqf (fun () -> run ctxt2 (compile e2)) ans3);
  ]);
  
] 
