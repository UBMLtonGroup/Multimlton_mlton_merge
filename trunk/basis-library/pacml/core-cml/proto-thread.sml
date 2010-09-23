structure ProtoThread : PROTO_THREAD =
struct

  structure Assert = LocalAssert(val assert = false)
  structure Debug = LocalDebug(val debug = false)

  open Critical
  structure TID = ThreadID
  structure MT = MLtonThread

  exception ThreadCasting of string

  fun debug msg = Debug.sayDebug ([atomicMsg, TID.tidMsg], msg)
  fun debug' msg = debug (fn () => msg^" : "^Int.toString(PacmlFFI.processorNumber()))

  type thread_id = ThreadID.thread_id
  type parasite = RepTypes.parasite
  datatype thread = datatype RepTypes.thread
  datatype rdy_thread = datatype RepTypes.rdy_thread
  datatype thread_type = datatype RepTypes.thread_type
  datatype runnable_host = datatype RepTypes.runnable_host


  (* Continuation management *)
  fun prepend (H_THRD (tid, t), f) = H_THRD (tid, MT.prepend (t, f))
    | prepend (P_THRD (par : parasite, g : (unit -> 'a) -> unit), f : 'b -> 'a) = P_THRD (par, fn h => g (f o h))

  fun prep (H_THRD (tid, t)) = H_RTHRD (RHOST (tid, MT.prepare (t, ())))
    | prep (P_THRD (par, g)) = (g (fn () => ()); P_RTHRD (par))

  fun prepVal (H_THRD (tid, t), v) = H_RTHRD (RHOST((tid, MT.prepare (t,v))))
    | prepVal (P_THRD (par, g), v) = (g (fn () => v); P_RTHRD (par))

  fun prepFn (H_THRD (tid, t), f) = H_RTHRD (RHOST ((tid, MT.prepare (MT.prepend (t,f), ()))))
    | prepFn (p, f) = prep (prepend (p, f))



  (* Manipulate current thread info *)
  fun getThreadState () =
    let
      val TID.TID {threadType, parasiteBottom, ...} = TID.getCurThreadId ()
    in
      (!threadType, !parasiteBottom)
    end

  fun setThreadState (s, n) =
    let
      val TID.TID {threadType, parasiteBottom, ...} = TID.getCurThreadId ()
      val _ = threadType := s
      val _ = parasiteBottom := n
    in
      ()
    end

  fun getThreadType () =
    let
      val TID.TID {threadType, ...} = TID.getCurThreadId ()
    in
      !threadType
    end

  fun getParasiteBottom () =
    let
      val TID.TID {parasiteBottom, ...} = TID.getCurThreadId ()
    in
      !parasiteBottom
    end


  fun setThreadType (t) =
    let
      val TID.TID {threadType, ...} = TID.getCurThreadId ()
    in
      threadType := t
    end

  fun setParasiteBottom (p) =
    let
      val TID.TID {parasiteBottom, ...} = TID.getCurThreadId ()
    in
      parasiteBottom := p
    end

  fun disableParasitePreemption () = (* XXX KC -- make it return the current state so that it can be restored *)
  let
    val TID.TID {preemptParasite, ...} = TID.getCurThreadId ()
  in
    preemptParasite := false
  end

  fun enableParasitePreemption () =
  let
    val TID.TID {preemptParasite, ...} = TID.getCurThreadId ()
  in
    preemptParasite := true
  end

  fun toPreemptParasite () =
  let
    val TID.TID {preemptParasite, ...} = TID.getCurThreadId ()
  in
    !preemptParasite
  end

  fun getThreadTypeString () =
    case getThreadType () of
         HOST => "HOST"
       | PARASITE => "PARASITE"

  (* Parasite management *)

  val extractParasiteFromHost = ParasiteFFI.extractParasiteFromHost
  val copyParasite = ParasiteFFI.copyParasite
  val proceedToExtractParasite = ParasiteFFI.proceedToExtractParasite
  val prefixAndSwitchTo = ParasiteFFI.prefixAndSwitchTo
  val getFrameBottomAsOffset = ParasiteFFI.getFrameBottomAsOffset
  val jumpDown = ParasiteFFI.jumpDown

  datatype prefix_kind = datatype RepTypes.prefix_kind

  fun atomicPrefixAndSwitchToHelper (thlet, kind) =
  let
    val state = getThreadState ()
    val _ = case kind of
                  PREFIX_REGULAR => setThreadType (PARASITE)
                | _ => ()
    fun doit () =
    let
      val _ = setParasiteBottom (getFrameBottomAsOffset ())
      val _ = prefixAndSwitchTo (thlet) (* Implicit atomic End *)
    in
      print "\natomicPrefixAndSwitchTo : Should not see this"
    end
    val _ = Primitive.dontInline doit

    (* control returns *)
    val _ = setThreadState (state)
    val _ = enableParasitePreemption ()
  in
    ()
  end

  fun atomicPrefixAndSwitchTo (thlet) = atomicPrefixAndSwitchToHelper (thlet, PREFIX_REGULAR)
  (* Special version does not set the thread type to parasite. Used when reifying a host thread
    * from a parasite.
    *)
  fun atomicPrefixAndSwitchToSpecial (thlet) = atomicPrefixAndSwitchToHelper (thlet, PREFIX_SPECIAL)

  fun getRunnableHost (rthrd) = case rthrd of
                                     H_RTHRD rhost => rhost
                                   | _ => raise ThreadCasting "getRunnableHost failed"

  fun spawnParasite f =
  let
    fun doit () =
    let
      val _ = setParasiteBottom (getFrameBottomAsOffset ())
      val _ = atomicEnd ()
      val _ = f ()
      val _ = disableParasitePreemption ()
    in
      PacmlFFI.noop () (* Needed to prevent inlining f () *)
    end
    val state = getThreadState ()
    val _ = atomicBegin ()
    val _ = setThreadType (PARASITE)
    val _ = Primitive.dontInline (doit)

    (* control returns *)
    val _ = debug' "ProtoThread.spawnParasite.resetting thread state"
    val _ = setThreadState (state)
    val _ = enableParasitePreemption ()
  in
    ()
  end

end
