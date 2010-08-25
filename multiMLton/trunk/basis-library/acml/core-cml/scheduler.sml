(* scheduler.sml
 * 2004 Matthew Fluet (mfluet@acm.org)
 *  Ported to MLton threads.
 *)

(* scheduler.sml
 *
 * COPYRIGHT (c) 1995 AT&T Bell Laboratories.
 * COPYRIGHT (c) 1989-1991 John H. Reppy
 *
 * This module implements the scheduling queues and preemption
 * mechanisms.
 *)

structure Scheduler : SCHEDULER =
   struct
      structure Assert = LocalAssert(val assert = true)
      structure GlobalDebug = Debug
      structure Debug = LocalDebug(val debug = false)
      structure Pointer = Primitive.MLton.Pointer

      open Critical

      structure T = MLtonThread
      structure TID = ThreadID
      structure SH = SchedulerHooks
      structure B = Basic
      structure Prim = Primitive.MLton.Threadlet
      structure Q = ImpQueue
      structure R = RepTypes

      type thread_id = ThreadID.thread_id
      type primThread = Primitive.MLton.Thread.thread
      type threadlet = Primitive.MLton.Thread.thread

      datatype thread = datatype RepTypes.thread
      datatype rdy_thread = datatype RepTypes.rdy_thread
      datatype thread_state = datatype RepTypes.thread_state


      fun prep (THRD (tid, t)) = RTHRD (tid, T.prepare (t, ()))
      fun prepVal (THRD (tid, t), v) = RTHRD (tid, T.prepare (t, v))
      fun prepFn (THRD (tid, t), f) = RTHRD (tid, T.prepare (T.prepend (t, f), ()))

      val fetchAndAdd = ParallelInternal.fetchAndAdd
      val printPointerAtOffset = _import "GC_printPointerAtOffset" : int -> unit;
      val getFrameBottomAsOffset = _import "GC_getFrameBottomAsOffset" : unit -> int;
      val noop = _import "GC_noop" : unit -> unit;


     (* the error thread.  This thread is used to trap attempts to run CML
       * without proper initialization (i.e., via RunCML).  This thread is
       * enqueued by reset.
       *)

     fun debug'' msg =  print (msg^"["^Int.toString(B.processorNumber())^"]\n")

     (* disable prints *)
     fun print str = ()

     fun printPointerAtOffset str = ()
     val numAsyncs = ref 0

     val PARASITE_ENABLED = ParallelInternal.PARASITE_ENABLED
     val doesAsyncPreempt = true

      val errorTid = TID.bogus "error"
      fun errorThrd () : unit thread =
         THRD (errorTid, T.new (fn () =>
               (GlobalDebug.sayDebug
                ([fn () => "CML"], fn () => "**** Use RunCML.doit to run CML ****")
                ; raise Fail "CML not initialized")))

      fun getThreadId (THRD (tid, _)) = tid
      val getCurThreadId = B.getCurThreadId
      fun tidMsg () = TID.tidToString (B.getCurThreadId ())
      fun tidNum () = TID.tidToInt (B.getCurThreadId ())

      fun debug msg = Debug.sayDebug ([atomicMsg, tidMsg], msg)
      fun debug' msg = debug (fn () => msg^" : "
                                    ^Int.toString(B.processorNumber()))



      (* This is setup in thread.sml *)
      val wrapFunction = ref NONE

      (* contains preempted asyncs *)
      val asyncQ = Array.tabulate (B.numberOfProcessors, fn _ => Q.new ())

      fun getThreadletState () =
        let
          val TID.TID {state, next, ...} = getCurThreadId ()
          val _ = print "\ngetThreadletState\n\tnext = "
          val _ = printPointerAtOffset (!next)
          val _ = case !state of
                       HOST => print "\n\tstate = HOST"
                     | PARASITE => print "\n\tstate = PARASITE"
          val _ = print "\n"
        in
          (!state, !next)
        end

     fun setThreadletState (s, n) =
        let
          val TID.TID {state, next, ...} = getCurThreadId ()
          val _ = state := s
          val _ = next := n
          val _ = print "\nsetThreadletState\n\tnext = "
          val _ = printPointerAtOffset (n)
          val _ = case !state of
                       HOST => print "\n\tstate = HOST"
                     | PARASITE => print "\n\tstate = PARASITE"
          val _ = print "\n"
        in
          ()
        end


     fun getThreadType () =
       let
         val TID.TID {state, ...} = getCurThreadId ()
       in
         !state
       end

     fun getNextPointer () =
       let
         val TID.TID {next, ...} = getCurThreadId ()
         val _ = print "\ngetNextPointer = "
         val _ = printPointerAtOffset (!next)
         val _ = print "\n"
       in
         !next
       end


     fun setThreadletType (s) =
       let
         val TID.TID {state, ...} = getCurThreadId ()
       in
         state := s
       end

     fun setNextPointer (p) =
       let
         val TID.TID {next, ...} = getCurThreadId ()
         val _ = print "\nsetNextPointer = "
         val _ = printPointerAtOffset (p)
         val _ = print "\n"
       in
         next := p
       end

      datatype prefix_kind = PREFIX_REGULAR | PREFIX_SPECIAL

      fun atomicPrefixAndSwitchToHelper (thlet, kind) =
      let
        val state = getThreadletState ()
        val _ = case kind of
                     PREFIX_REGULAR => setThreadletType (PARASITE)
                   | _ => ()
        fun doit () =
        let
          val _ = setNextPointer (getFrameBottomAsOffset ())
          val _ = Prim.prefixAndSwitchTo (thlet) (* Implicit atomic End *)
        in
          print "\natomicPrefixAndSwitchTo : Should not see this"
        end
        val _ = Primitive.dontInline doit
        val _ = setThreadletState (state)
      in
        ()
      end


      fun atomicPrefixAndSwitchTo (thlet) = atomicPrefixAndSwitchToHelper (thlet, PREFIX_REGULAR)
      (* Special version does not set the thread type to parasite. Used when reifying a host thread
       * from a parasite.
       *)
      fun atomicPrefixAndSwitchToSpecial (thlet) = atomicPrefixAndSwitchToHelper (thlet, PREFIX_SPECIAL)

      fun async f =
      let
        fun doit () =
        let
          val _ = setNextPointer (getFrameBottomAsOffset ())
          val _ = f ()
        in
          noop () (* Needed to prevent inlining f () *)
        end
        val state = getThreadletState ()
        val _ = setThreadletType (PARASITE)
        val _ = Primitive.dontInline (doit)
        val _ = atomicBegin ()
        val _ = setThreadletState (state)
        val _ = atomicEnd ()
      in
        ()
      end

      fun enqueA x =
      let
        val _ = if (not PARASITE_ENABLED) then Assert.fail ("Scheduler.enqueA") else ()
        val _ = debug' "Enque async"
        val q = Array.sub (asyncQ, B.processorNumber ())
        val _ = Q.enque (q, x)
        val n = fetchAndAdd (numAsyncs, 1)
      in
        ()
      end

      fun dequeA () =
        if (not PARASITE_ENABLED) then
          NONE
        else
      (let
        val _ = debug' "Deque async"
        val q = Array.sub (asyncQ, B.processorNumber ())
        val async = Q.deque (q)
        val _ = case async of
                     SOME _ => ignore (fetchAndAdd (numAsyncs , ~1))
                   | NONE => ()
      in
        async
      end)

     fun emptyA () =
       (if (not PARASITE_ENABLED) then
         true
       else
        (let
          val q = Array.sub (asyncQ, B.processorNumber ())
        in
          Q.empty (q)
        end))


      (* enqueue a thread in the primary queue *)
      fun enque1 thrd forceSame =
         (Assert.assertAtomic' ("Scheduler.enque1", NONE)
          ; B.addWork thrd forceSame R.PRI)
      (* enqueue a thread in the secondary queue *)
      fun enque2 thrd forceSame =
         (Assert.assertAtomic' ("Scheduler.enque2", NONE)
          ; B.addWork thrd forceSame R.SEC)

      (* dequeue a thread from the primary queue *)
      fun deque1 () =
         (Assert.assertAtomic' ("Scheduler.deque1", NONE)
          ;  case B.getWork R.PRI of
                  NONE => deque2 ()
                | w => w)
      (* dequeue a thread from the secondary queue *)
      and deque2 () =
         (Assert.assertAtomic' ("Scheduler.deque1", NONE)
          ;  B.getWork R.SEC)
      (* promote a thread from the secondary queue to the primary queue *)
      fun promote () =
        (Assert.assertAtomic' ("Scheduler.promote", NONE)
        ; case deque2 () of
              NONE => ()
            | SOME thrd => enque1 thrd true)

      (**
      * Joins together an async to a runnable CML thread
      *
      * @param parsite
      * @param runnable CML thread
      *
      * @return newly spliced thread
      *)
      fun spliceParasiteToHost (parasite, RTHRD (tid, t)) =
      let
        val _ = debug' ("Scheduler.spliceParasiteToHost")
        val wf = valOf (!wrapFunction)
        val newT = T.new (wf (fn () => (T.atomicBegin ();
        atomicPrefixAndSwitchToSpecial (parasite);
        ignore (T.switch (fn _ => t));
        noop ()))
        tid)
        val newRT = T.prepare (newT, ())
      in
        RTHRD (tid, newRT)
      end



      fun next' iter =
        if B.empty () andalso emptyA () then
          (!SH.pauseHook(iter))
        else
         (let
            val () = Assert.assertAtomic' ("Scheduler.next", NONE)
            val wf = valOf (!wrapFunction)
            val thrd =
               case deque1 () of
                  NONE => if (emptyA ()) then (!SH.pauseHook (iter))
                           else (* we are going to reify parasite into a host *)
                           (let
                             val () = if (not PARASITE_ENABLED) then Assert.fail ("Scheduler.next") else ()
                             (* This must be done before deque to avoid race
                              * causing premature termination of program *)
                             val _ = debug' "Reifying host thread from parasite"
                             val _ = fetchAndAdd (B.numThreadsLive, 1)
                             (* creating a container for parasite to run *)
                             val tid = TID.new ()
                             val nT = T.new (wf (fn () => debug' "Starting reified thread") tid)
                             val nRt = T.prepare (nT, ())
                            in
                              RTHRD (tid, nRt)
                            end)
                | SOME thrd => thrd
           val parasite = dequeA ()
           val thrd' = case parasite of
                           NONE => thrd
                         | SOME a => spliceParasiteToHost (a, thrd)
         in
           thrd'
         end)

     fun next () = next' 0

     fun finishWork () =
     let
       val r = B.finishWork ()
       val  res = r andalso (!numAsyncs = 0)
       val _ = debug'' ("FinishWork - NumAsyncs = "^(Int.toString(!numAsyncs))^"; NumThreadsLive = "^(Int.toString(!B.numThreadsLive)))
     in
       res
     end

     fun readySpawn thrd forceSame =
     let
       val () = Assert.assertAtomic' ("Scheduler.readySpawn", NONE)
     in
       (case forceSame of
             R.CUR_PROC => enque1 thrd true
           | R.ANY_PROC => enque1 thrd false)
     end

      fun ready thrd = readySpawn thrd R.CUR_PROC (* forceSame = true *)

      fun readyOnProc (thrd,procNum) = B.addWorkTo thrd procNum R.PRI

      local
         fun atomicSwitchAux msg f =
            (Assert.assertAtomic (fn () => "Scheduler." ^ msg, NONE)
             ; T.atomicSwitch (fn t =>
                               let
                                  val tid = B.getCurThreadId ()
                                  val () = TID.mark tid
                                  val RTHRD (tid',t') = f (THRD (tid, t))
                                  val () = B.setCurThreadId tid'
                                  val () = debug' "Scheduler.atomicSwitchAux"
                               in
                                  t'
                               end))
      in
         fun atomicSwitch (f: 'a thread -> rdy_thread) =
            atomicSwitchAux "atomicSwitch" f
         fun switch (f: 'a thread -> rdy_thread) =
            (atomicBegin (); atomicSwitch f)
         fun atomicSwitchToNext (f: 'a thread -> unit) =
            atomicSwitchAux "atomicSwitchToNext" (fn thrd => (f thrd; next ()))
         fun switchToNext (f: 'a thread -> unit) =
            (atomicBegin (); atomicSwitchToNext f)
         fun atomicReadyAndSwitch (f: unit -> rdy_thread) =
            atomicSwitchAux "atomicReadyAndSwitch" (fn thrd => (ready (prep thrd); f ()))
         fun readyAndSwitch (f: unit -> rdy_thread) =
            (atomicBegin (); atomicReadyAndSwitch f)
         fun atomicReadyAndSwitchToNext (f: unit -> unit) =
            atomicSwitchAux "atomicReadyAndSwitchToNext" (fn thrd => (ready (prep thrd); f (); next ()))
         fun readyAndSwitchToNext (f: unit -> unit) =
            (atomicBegin (); atomicReadyAndSwitchToNext f)
      end

      fun new (f : thread_id -> ('a -> unit)) : 'a thread =
         let
            val () = Assert.assertAtomic' ("Scheduler.new", NONE)
            val tid = TID.new ()
            val t = T.new (f tid)
         in
            THRD (tid, t)
         end


       fun new' (f : thread_id -> (unit -> unit)) : unit thread =
          let
            val () = Assert.assertAtomic' ("Scheduler.new", NONE)
            val wf = valOf (!wrapFunction)
            val tid = TID.new ()
            val t = T.new (wf (f tid) tid)
            (* XXX KC It is assumed that the result thread is put into the scheduler.
             * Otherwise, numThreadsLive is incorrect *)
            val _ = ParallelInternal.fetchAndAdd (B.numThreadsLive, 1)
          in
            THRD (tid, t)
          end



      fun prepend (thrd : 'a thread, f : 'b -> 'a) : 'b thread =
         let
            val () = Assert.assertAtomic' ("Scheduler.prepend", NONE)
            val THRD (tid, t) = thrd
            val t = T.prepend (t, f)
         in
            THRD (tid, t)
         end


      (**
      * Extracts a parasite from the top of the host
      *
      * @param host - primThread
      * @param start - start of parasite on host stack
      *
      * @return - threadlet
      *)
      val extractParasiteFromHost = _import "GC_preemptAsync" : primThread * int -> threadlet;

      (**
      * Inflate and async to a CML thread
      *
      * @param parasite
      *
      * @return runnable CML thread
      *)
      fun reifyHostFromParasite (parasite) =
      let
        val wf = valOf (!wrapFunction)
        val _ = debug'' ("Reifying host from parasite. NumThreads = "^(Int.toString(!B.numThreadsLive)))
        (* creating a container for async to run *)
        val tid = TID.new ()
        val nT = T.new (wf (fn () => debug' "Dummy thread") tid)
        val nRt = T.prepare (nT, ())
      in
        spliceParasiteToHost (parasite, RTHRD (tid, nRt))
      end

      fun unwrap (f : rdy_thread -> rdy_thread) (host: T.Runnable.t) : T.Runnable.t =
         let
            val () = debug' "Scheduler.unwrap"
            val () = Assert.assertAtomic' ("Scheduler.unwrap", NONE)
            val state = getThreadType ()
            val host' = case (state, doesAsyncPreempt) of
                       (PARASITE, true) =>
                            let
                              val host' = T.toPrimitive host
                              val thlet = extractParasiteFromHost (host', getNextPointer())
                              val newHost = reifyHostFromParasite (thlet)
                              val _ = readySpawn newHost R.ANY_PROC (* Will add 1 to numThreadsLive *)
                              val host'' = T.fromPrimitive host'
                            in
                              host''
                            end
                        | _ =>
                            let
                              val tid = B.getCurThreadId ()
                              val RTHRD (tid', host') = f (RTHRD (tid, host))
                              val () = B.setCurThreadId tid'
                            in
                              host'
                            end

         in
            host'
         end


      (* reset various pieces of state *)
      fun reset running =
         (atomicBegin ()
          ; if running then debug' "Scheduler.reset true"
            else  debug' "Scheduler.reset false"
          ; B.clearWork ()
          ; if not running then ready (prep (errorThrd ())) else ()
          ; atomicEnd ())

      (* what to do at a preemption (with the current thread) *)
      fun preempt (thrd as RTHRD(tid, _)) =
         let
            val () = Assert.assertAtomic' ("Scheduler.preempt", NONE)
            val () = print "Scheduler.preempt" (* Atomic 1 *)
            val () = Assert.assertAtomic' ("Scheduler.preempt", SOME 1)
            val () =
             if TID.isMarked tid
             then (TID.unmark tid
                   ; promote ()
                   ; B.addWorkTo thrd (B.processorNumber()) R.PRI)
             else B.addWorkTo thrd (B.processorNumber()) R.SEC
         in
            ()
         end

      val _ = reset false

   end
