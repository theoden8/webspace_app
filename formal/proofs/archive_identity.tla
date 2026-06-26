------------------------ MODULE archive_identity ------------------------
(***************************************************************************)
(* TLAPS proof that ARCH-001 byte-identity holds for UNBOUNDED archives    *)
(* and writes. TLC checks archive.tla at MaxSteps = 3 / MaxArch = 2; this  *)
(* proves ByteIdentity (appA = appB) for the no-leak system at any bounds. *)
(* Standard inductive-invariant argument over the self-composition.        *)
(***************************************************************************)
EXTENDS archive, TLAPS

ASSUME NoLeak == Leak = FALSE
ASSUME Bounds == MaxSteps \in Nat /\ MaxArch \in Nat

SpecArchive == Init /\ [][Next]_vars

IndInv == TypeOK /\ ByteIdentity

LEMMA InitEstablishes == Init => IndInv
  BY Bounds DEF Init, IndInv, TypeOK, ByteIdentity

LEMMA InductiveStep == IndInv /\ [Next]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [Next]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE NoLeak, Bounds DEF IndInv, TypeOK, ByteIdentity
  <1>1. CASE AppWrite
    BY <1>1 DEF AppWrite
  <1>2. CASE ArchiveLifecycle
    BY <1>2 DEF ArchiveLifecycle
  <1>3. CASE UNCHANGED vars
    BY <1>3 DEF vars
  <1> QED
    BY <1>1, <1>2, <1>3 DEF Next

THEOREM Safety == SpecArchive => []ByteIdentity
  <1>1. Init => IndInv
    BY InitEstablishes
  <1>2. IndInv /\ [Next]_vars => IndInv'
    BY InductiveStep
  <1>3. IndInv => ByteIdentity
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF SpecArchive
=============================================================================
