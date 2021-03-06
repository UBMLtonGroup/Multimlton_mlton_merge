structure Lock :> LOCK =
struct

    val pN = ParallelInternal.processorNumber

    val fetchAndAdd = ParallelInternal.fetchAndAdd
    val cas = ParallelInternal.compareAndSwap
    val mayBeWaitForGC = _import "Parallel_maybeWaitForGC": unit -> unit;

    type cmlLock = (int ref * int ref)

    fun initCmlLock () =
      let
        val l = (ref ~1, ref 0)
      in
        l
      end

    fun maybePreempt () = if not (MLtonThread.amSwitching (pN ())) then
                           (MLtonThread.atomicEnd ();
                              MLtonThread.atomicBegin ())
                          else
                            ()
    fun getCmlLock (l, count) ftid =
    let
      val _ =
      mayBeWaitForGC ()
      val tid = ftid () (* Has to be this way to account for parasite reification at maybePreempt *)
    in
      if !l = tid then
        count := !count +1
      else
        (* Don't bang on CAS. spin on conditional *)
        (if !l < 0 then
          (if cas (l, ~1, tid) then
            ()
          else
            (maybePreempt ();
            getCmlLock (l, count) ftid))
        else
          (maybePreempt ();
          getCmlLock (l, count) ftid))
    end

    fun releaseCmlLock (l,count) tid =
      if !l = tid andalso !count > 0 then
          count := !count - 1
      else
        if cas (l, tid, ~1) then
           mayBeWaitForGC ()
        else
          let
            val holder = Int.toString(!l)
            val attempt = Int.toString(tid)
            val msg = ("Parallel.Lock : Can't unlock if you dont hold the lock"
                      ^" Currently held by "^holder
                      ^" Failed attempt by "^attempt)
          in
            raise Fail msg
          end

  fun assertLock ((l,count), i, m) = Assert.assert' (m^" "^(Int.toString (i)), fn () => !l = i)
end
