structure Main =
struct
   open CML

    val c2 = channel ()
    fun prod c 0 = send (c2, "DONE")
      | prod c n = (send (c,1); prod c (n-1))

    fun cons c 0 = ()
      | cons c n = (ignore (recv c); cons c (n-1))

   fun doit n =
      RunCML.doit
      (fn () =>
       let
         val c = channel ()
         val _ = spawn (fn () => prod c n)
         val _ = spawn (fn () => cons c n)
       in
         ignore( recv c2 )
       end,
       SOME (Time.fromMilliseconds 10))
end


val n = valOf (Int.fromString (hd (CommandLine.arguments ()))) handle _ => 600
val _ = Main.doit n
