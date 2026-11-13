------------------------------ MODULE tls_trust ------------------------------
(***************************************************************************)
(* The TLS trust prompt's timing (TLS-002, TLS-003, TLS-004, TLS-005,      *)
(* TLS-006, TLS-012, TLS-013), as lib/services/webview_tls.dart and        *)
(* lib/services/trusted_hosts_service.dart run it on Android and Linux.    *)
(* iOS and macOS return null before any of it (webview_tls.dart:77, 361;   *)
(* TLS-009), so they are not modelled.                                     *)
(*                                                                         *)
(* What interleaves: certificates the OS rejected, met by several views    *)
(* and hosts at once through three entries,                                *)
(*   "trust"  handleServerTrust with the page's hooks (webview.dart:1845)  *)
(*   "bare"   handleServerTrust with no hooks: a popup or a background     *)
(*            wake's headless check (popup_webview.dart:275,               *)
(*            headless_site_check.dart:132)                                *)
(*   "error"  handleSslLoadError, the main frame's load error              *)
(*            (webview.dart:1731), which shows the certificate the last    *)
(*            trust callback for its host:port cached (webview_tls.dart:   *)
(*            68, 369)                                                     *)
(* each split at its awaits: the OS's portal verdict (webview_tls.dart:80, *)
(* 190, 372), the user's answer (232) and the pin's write to disk          *)
(* (trusted_hosts_service.dart:154, after the pin is in memory at 153).    *)
(* Between them: the OS starts or stops reporting a captive portal, a view *)
(* goes away with its prompt still open, a pin is revoked in settings, and *)
(* a Dart client (outbound_http_io.dart:349, 382) reads the pins in a      *)
(* handshake of its own. The sinkhole and https-upgrade carve-outs         *)
(* (webview_tls.dart:106-131) only cancel, so leaving them out leaves out  *)
(* no pin and no let-through.                                              *)
(*                                                                         *)
(* A host stands for a host:port. A certificate is a fingerprint in Certs, *)
(* or one in NoDer, which the platform gave without its bytes (TLS-006),   *)
(* known by its host instead (webview_tls.dart:221).                       *)
(*                                                                         *)
(* Each step records what it did in [ev], so an invariant over [ev] checks *)
(* every such event in the state it lands in. Each reads the ghosts the    *)
(* event recorded, never the guard it checks:                              *)
(*   Inv_PinAccepted       every pin is a (host, certificate) the user     *)
(*                         accepted in a prompt that showed exactly it     *)
(*   Inv_PassPinned        a rejected certificate is let through only for  *)
(*                         a (host, certificate) the user accepted, and on *)
(*                         a pin only while the pin is exactly it          *)
(*   Inv_LateAnswer        an answer that lands after its view went away   *)
(*                         pins the certificate its prompt showed          *)
(*   Inv_NoAskInPortal     no prompt opens while the OS reports a portal   *)
(*                         (TLS-012)                                       *)
(*   Inv_NoWebPinPassInPortal  no webview lets a certificate through on a  *)
(*                         pin while the OS reports a portal (TLS-012)     *)
(*   Inv_DeclinedNotAsked  a declined certificate is not asked about again *)
(*                         in the run, for any host (TLS-013)              *)
(*   Inv_NoPinInPortal     nothing is pinned while the OS reports a portal, *)
(*                         an Accept that lands in one included (TLS-012)  *)
(*   Inv_ShownOwn          a prompt shows a certificate its own view met,  *)
(*                         or none (SEC-054)                               *)
(*   Inv_OneAtATime        one certificate has one prompt open at a time   *)
(*                         (TLS-002, TLS-013)                              *)
(*                                                                         *)
(* Mistakes that MUST be caught (Mistake):                                 *)
(*   anyfp         a pin matches its host whatever the certificate         *)
(*   pinonopen     the certificate is pinned as its prompt opens, before   *)
(*                 the user answers                                        *)
(*   latecache     the answer pins the certificate cached for the host     *)
(*                 when it lands, not the one its prompt showed            *)
(*   noportal      the portal verdict is not read                          *)
(*   staleverdict  the verdict is the one the OS gave as the challenge     *)
(*                 arrived, not the one it gives at the read               *)
(*   forget        a decline is not remembered                             *)
(*   noasking      a prompt does not wait for one already open on its      *)
(*                 certificate                                             *)
(*   answerunread  the verdict is not read again as an Accept lands, so a  *)
(*                 portal reported while the prompt was open is pinned     *)
(*   sharedcache   one certificate cache for every view of a host, written *)
(*                 by any trust callback, so a load error prompts with     *)
(*                 another view's certificate                              *)
(*                                                                         *)
(* What the spec says and the code does not, the Gap invariants: each      *)
(* tls_trust_gap cfg reproduces the code's counterexample, and none is     *)
(* in check.sh, since a fix changes the action, not the cfg:               *)
(*   Gap_NoPinPassInPortal TLS-012 "a pin the user made earlier for that   *)
(*                         certificate is not honoured"; the Dart clients  *)
(*                         honour it, reading no verdict                   *)
(*                         (outbound_http_io.dart:349, 382)                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Views,          \* webviews that run as a site (a popup's challenges
                    \* count as its opener's)
    Hosts,          \* host:port pairs
    Certs,          \* certificates whose bytes the platform gave
    NoDer,          \* {} or the one certificate without them (TLS-006)
    None,           \* no certificate: an empty pin or cache slot
    Entries,        \* which of "trust", "bare", "error" a world takes
    MaxChallenges,  \* rejected handshakes in a behaviour
    MaxDart,        \* Dart client handshakes in a behaviour
    MaxRevokes,     \* pins removed in settings in a behaviour
    Mistake

Mistakes == {"none", "anyfp", "pinonopen", "latecache", "noportal",
             "staleverdict", "forget", "noasking", "answerunread",
             "sharedcache"}
Paths == {"trust", "bare", "error"}
ASSUME Mistake \in Mistakes
ASSUME Entries \subseteq Paths
ASSUME NoDer \cap Certs = {} /\ None \notin Certs \cup NoDer /\ Cardinality(NoDer) <= 1
ASSUME Hosts \cap Certs = {}

AllCerts == Certs \cup NoDer
Slots == 1..MaxChallenges

\* What _ask knows a certificate by (webview_tls.dart:221-223).
Key(h, c) == IF c \in Certs THEN c ELSE h
Keys == Certs \cup Hosts

Challenge == [view : Views, host : Hosts, cert : AllCerts \cup {None},
              path : Paths, pc : {"verdict", "prompt", "persist", "fin"},
              portal0 : BOOLEAN]
\* A slot no challenge holds, or one that has ended.
Fin == [view |-> CHOOSE v \in Views : TRUE, host |-> CHOOSE h \in Hosts : TRUE,
        cert |-> None, path |-> "trust", pc |-> "fin", portal0 |-> FALSE]

\* What a step did, as the invariants read it.
NoEv == [kind |-> "none", how |-> "none", client |-> "none", why |-> "none",
         portal |-> FALSE, accepted |-> TRUE, pinned |-> TRUE,
         declinedBefore |-> FALSE, own |-> TRUE, shown |-> TRUE, late |-> FALSE]

VARIABLES
    \* The environment.
    portal,      \* the OS reports a captive portal (NetworkSignIn.verdict)
    alive,       \* which views are still there
    \* The code's state.
    pins,        \* TrustedHostsService._byHostPort
    cache,       \* WebViewTls._certsSeen: per view, by host:port
    declined,    \* WebViewTls._declined
    asking,      \* WebViewTls._asking
    inflight,    \* WebViewTls._inflightSslPrompts
    ch,          \* each challenge, at its await
    used, dart, revokes,
    \* Ghosts the invariants read.
    presented,   \* << view, host, cert >> each view's connections met
    accepted,    \* << host, cert >> the user accepted in a prompt showing it
    declinedEver,\* keys the user declined
    ev           \* what the last step did

env == << portal, alive >>
code == << pins, cache, declined, asking, inflight, ch, used, dart, revokes >>
ghosts == << presented, accepted, declinedEver >>
vars == << env, code, ghosts, ev >>

TypeOK ==
    /\ portal \in BOOLEAN
    /\ alive \in [Views -> BOOLEAN]
    /\ pins \in [Hosts -> Certs \cup {None}]
    /\ cache \in [Views -> [Hosts -> AllCerts \cup {None}]]
    /\ declined \subseteq Keys
    /\ asking \subseteq Keys
    /\ inflight \subseteq Hosts
    /\ ch \in [Slots -> Challenge]
    /\ used \in 0..MaxChallenges
    /\ dart \in 0..MaxDart
    /\ revokes \in 0..MaxRevokes
    /\ presented \subseteq Views \X Hosts \X AllCerts
    /\ accepted \subseteq Hosts \X AllCerts
    /\ declinedEver \subseteq Keys

Init ==
    /\ portal = FALSE
    /\ alive = [v \in Views |-> TRUE]
    /\ pins = [h \in Hosts |-> None]
    /\ cache = [v \in Views |-> [h \in Hosts |-> None]]
    /\ declined = {}
    /\ asking = {}
    /\ inflight = {}
    /\ ch = [i \in Slots |-> Fin]
    /\ used = 0
    /\ dart = 0
    /\ revokes = 0
    /\ presented = {}
    /\ accepted = {}
    /\ declinedEver = {}
    /\ ev = NoEv

\* TrustedHostsService.isTrusted (trusted_hosts_service.dart:137-145): a
\* null fingerprint is no proof.
IsTrusted(h, c) ==
    IF Mistake = "anyfp" THEN pins[h] # None
    ELSE c \in Certs /\ pins[h] = c

\* A rejected certificate let through: whether the user had accepted it for
\* its host by then (in [acc]), and whether the host's pin was it, each read
\* here apart from the guard that let it through.
PassEv(h, c, how, client, acc) ==
    [NoEv EXCEPT !.kind = "pass", !.how = how, !.client = client,
                 !.portal = portal, !.accepted = << h, c >> \in acc,
                 !.pinned = (pins[h] = c)]

\* A rejection cancelled without a prompt, and why.
QuietEv(why) == [NoEv EXCEPT !.kind = "quiet", !.why = why]

\* --- The environment ------------------------------------------------------

\* The OS starts or stops reporting a captive portal on the network
\* (Android's NET_CAPABILITY_CAPTIVE_PORTAL, NetworkManager's PORTAL).
PortalFlip ==
    /\ portal' = ~portal
    /\ ev' = NoEv
    /\ UNCHANGED << alive, code, ghosts >>

\* A view goes away (a switch, an unload, a popup closing), its prompt, if
\* any, still on the page's context (webview_prompts.dart:91-101).
ViewGone(v) ==
    /\ alive[v]
    /\ alive' = [alive EXCEPT ![v] = FALSE]
    /\ ev' = NoEv
    /\ UNCHANGED << portal, code, ghosts >>

\* The user removes a pin in settings (trusted_hosts_service.dart:162-178).
Revoke(h) ==
    /\ revokes < MaxRevokes
    /\ pins[h] # None
    /\ pins' = [pins EXCEPT ![h] = None]
    /\ revokes' = revokes + 1
    /\ ev' = NoEv
    /\ UNCHANGED << env, cache, declined, asking, inflight, ch, used, dart, ghosts >>

\* A Dart client's handshake the platform rejected: badCertificateCallback
\* (outbound_http_io.dart:349, 382) lets it through on a pin, synchronously,
\* reading no verdict.
DartConnect(h, c) ==
    /\ dart < MaxDart
    /\ IsTrusted(h, c)
    /\ dart' = dart + 1
    /\ ev' = PassEv(h, c, "pin", "dart", accepted)
    /\ UNCHANGED << env, pins, cache, declined, asking, inflight, ch, used, revokes,
                    ghosts >>

\* --- A rejected certificate ----------------------------------------------

\* The trust callback for a handshake on [v] to [h] whose certificate [c]
\* the OS rejected (onReceivedServerTrustAuthRequest, webview.dart:1845;
\* popup_webview.dart:275; headless_site_check.dart:132): a view that can
\* prompt keeps the certificate it met (webview_tls.dart:65-71) and asks the
\* OS for its verdict (80, 190).
ArriveTrust(v, h, c, p) ==
    /\ used < MaxChallenges
    /\ alive[v]
    /\ ch' = [ch EXCEPT ![used + 1] = [view |-> v, host |-> h, cert |-> c,
                path |-> p, pc |-> "verdict", portal0 |-> portal]]
    /\ used' = used + 1
    /\ cache' = IF Mistake = "sharedcache"
                THEN [w \in Views |-> [cache[w] EXCEPT ![h] = c]]
                ELSE IF p = "trust" THEN [cache EXCEPT ![v][h] = c] ELSE cache
    /\ presented' = presented \cup {<< v, h, c >>}
    /\ ev' = NoEv
    /\ UNCHANGED << env, pins, declined, asking, inflight, dart, revokes,
                    accepted, declinedEver >>

\* The main frame's load on [v] to [h] failed with a certificate error,
\* after a trust callback for it (onReceivedError, webview.dart:1726-1735):
\* it reads the certificate its own view met for the host
\* (webview_tls.dart:368-371) and asks the OS for its verdict (372).
ArriveError(v, h) ==
    /\ used < MaxChallenges
    /\ alive[v]
    /\ \E c \in AllCerts : << v, h, c >> \in presented
    \* A view with no certificate of its own met asks nothing (SEC-054).
    /\ cache[v][h] # None
    /\ ch' = [ch EXCEPT ![used + 1] = [view |-> v, host |-> h, cert |-> cache[v][h],
                path |-> "error", pc |-> "verdict", portal0 |-> portal]]
    /\ used' = used + 1
    /\ ev' = NoEv
    /\ UNCHANGED << env, pins, cache, declined, asking, inflight, dart, revokes,
                    ghosts >>

\* The verdict as the challenge reads it.
Held(r) ==
    CASE Mistake = "noportal" -> FALSE
      [] Mistake = "staleverdict" -> r.portal0
      [] OTHER -> portal

\* The prompt opens (webview_tls.dart:230-233): asking takes the key, and
\* on the error path the host's in-flight mark (396).
OpenPrompt(i, r) ==
    LET k == Key(r.host, r.cert) IN
    /\ ch' = [ch EXCEPT ![i].pc = "prompt"]
    /\ asking' = asking \cup {k}
    /\ inflight' = IF r.path = "error" THEN inflight \cup {r.host} ELSE inflight
    /\ pins' = IF Mistake = "pinonopen" /\ r.cert \in Certs
               THEN [pins EXCEPT ![r.host] = r.cert] ELSE pins
    /\ ev' = [NoEv EXCEPT !.kind = "ask", !.portal = portal,
                          !.declinedBefore = (k \in declinedEver),
                          !.own = (r.cert = None
                                   \/ << r.view, r.host, r.cert >> \in presented)]

\* The verdict arrives, and the code runs on to its next await.
Verdict(i) ==
    /\ ch[i].pc = "verdict"
    /\ LET r == ch[i]
           k == Key(r.host, r.cert)
           done == ch' = [ch EXCEPT ![i] = Fin]
           \* _ask turns it away without a prompt (224-230).
           refused == k \in declined \/ (k \in asking /\ Mistake # "noasking")
           why == IF k \in declined THEN "declined" ELSE "asking"
       IN
       \/ \* The OS reports a portal: cancel, ask nothing, pin nothing
          \* (webview_tls.dart:80-83, 186-203; 372-374).
          /\ Held(r)
          /\ done
          /\ ev' = IF IsTrusted(r.host, r.cert) THEN QuietEv("portalpin")
                   ELSE QuietEv("portal")
          /\ UNCHANGED << pins, asking, inflight >>
       \/ /\ ~Held(r)
          /\ IF r.path \in {"trust", "bare"}
             THEN \/ \* Pinned: PROCEED (84-94).
                     /\ IsTrusted(r.host, r.cert)
                     /\ done
                     /\ ev' = PassEv(r.host, r.cert, "pin", "web", accepted)
                     /\ UNCHANGED << pins, asking, inflight >>
                  \/ \* No hooks: CANCEL (134-140).
                     /\ ~IsTrusted(r.host, r.cert)
                     /\ r.path = "bare"
                     /\ done
                     /\ ev' = QuietEv("nohooks")
                     /\ UNCHANGED << pins, asking, inflight >>
                  \/ /\ ~IsTrusted(r.host, r.cert)
                     /\ r.path = "trust"
                     /\ IF refused
                        THEN /\ done
                             /\ ev' = QuietEv(why)
                             /\ UNCHANGED << pins, asking, inflight >>
                        ELSE OpenPrompt(i, r)
             ELSE \/ \* Pinned: a stale error; reload once, let nothing
                     \* through here (375-394).
                     /\ IsTrusted(r.host, r.cert)
                     /\ done
                     /\ ev' = NoEv
                     /\ UNCHANGED << pins, asking, inflight >>
                  \/ \* A prompt for the host is out on this path (396).
                     /\ ~IsTrusted(r.host, r.cert)
                     /\ r.host \in inflight
                     /\ done
                     /\ ev' = QuietEv("inflight")
                     /\ UNCHANGED << pins, asking, inflight >>
                  \/ /\ ~IsTrusted(r.host, r.cert)
                     /\ r.host \notin inflight
                     /\ IF refused
                        THEN /\ done
                             /\ ev' = QuietEv(why)
                             /\ UNCHANGED << pins, asking, inflight >>
                        ELSE OpenPrompt(i, r)
    /\ UNCHANGED << env, cache, declined, used, dart, revokes, ghosts >>

\* The user answers a prompt, whether or not its view is still there
\* (webview_tls.dart:232-242). A decline is remembered for the run; an
\* accept reads the portal verdict again and, while the OS reports one,
\* cancels and pins nothing (TLS-012); else it pins the certificate the
\* prompt showed, in memory at once (trusted_hosts_service.dart:153), then
\* awaits the disk (154).
Answer(i, yes) ==
    /\ ch[i].pc = "prompt"
    /\ \E w \in Views : LET r == ch[i]
           k == Key(r.host, r.cert)
           \* latecache: what some view met for the host since, w's.
           pinned == IF Mistake = "latecache" THEN cache[w][r.host] ELSE r.cert
       IN
       /\ asking' = asking \ {k}
       /\ IF ~yes
          THEN /\ declined' = IF Mistake = "forget" THEN declined ELSE declined \cup {k}
               /\ declinedEver' = declinedEver \cup {k}
               /\ ch' = [ch EXCEPT ![i] = Fin]
               /\ inflight' = IF r.path = "error" THEN inflight \ {r.host} ELSE inflight
               /\ ev' = NoEv
               /\ UNCHANGED << pins, accepted >>
          ELSE /\ accepted' = accepted \cup {<< r.host, r.cert >>}
               /\ UNCHANGED << declined, declinedEver >>
               /\ IF portal /\ Mistake # "answerunread"
                  THEN /\ ch' = [ch EXCEPT ![i] = Fin]
                       /\ ev' = QuietEv("portal")
                       /\ inflight' = IF r.path = "error" THEN inflight \ {r.host}
                                      ELSE inflight
                       /\ UNCHANGED pins
                  ELSE IF r.cert \in Certs
                  THEN /\ pins' = IF pinned \in Certs
                                  THEN [pins EXCEPT ![r.host] = pinned] ELSE pins
                       /\ ev' = [NoEv EXCEPT !.kind = "write", !.portal = portal,
                                             !.shown = (pinned = r.cert),
                                             !.late = ~alive[r.view]]
                       /\ ch' = [ch EXCEPT ![i].pc = "persist"]
                       /\ UNCHANGED inflight
                  ELSE \* No bytes, no pin (TLS-006): the trust path
                       \* proceeds for this handshake alone (156-172), the
                       \* error path gives up (401-406).
                       /\ ch' = [ch EXCEPT ![i] = Fin]
                       /\ ev' = IF r.path = "trust"
                                THEN PassEv(r.host, r.cert, "accept", "web", accepted')
                                ELSE NoEv
                       /\ inflight' = IF r.path = "error" THEN inflight \ {r.host}
                                      ELSE inflight
                       /\ UNCHANGED pins
    /\ UNCHANGED << env, cache, used, dart, revokes, presented >>

\* The pin reaches disk: the trust path returns PROCEED (171), the error
\* path reloads and lets its host's next prompt through (415-418).
Persisted(i) ==
    /\ ch[i].pc = "persist"
    /\ LET r == ch[i] IN
       /\ ch' = [ch EXCEPT ![i] = Fin]
       /\ ev' = IF r.path = "trust"
                THEN PassEv(r.host, r.cert, "accept", "web", accepted)
                ELSE NoEv
       /\ inflight' = IF r.path = "error" THEN inflight \ {r.host} ELSE inflight
    /\ UNCHANGED << env, pins, cache, declined, asking, used, dart, revokes, ghosts >>

Next ==
    \/ PortalFlip
    \/ \E v \in Views : ViewGone(v)
    \/ \E h \in Hosts : Revoke(h)
    \/ \E h \in Hosts, c \in AllCerts : DartConnect(h, c)
    \/ \E v \in Views, h \in Hosts, c \in AllCerts, p \in Entries \ {"error"} :
         ArriveTrust(v, h, c, p)
    \/ "error" \in Entries /\ \E v \in Views, h \in Hosts : ArriveError(v, h)
    \/ \E i \in Slots : Verdict(i)
    \/ \E i \in Slots, yes \in BOOLEAN : Answer(i, yes)
    \/ \E i \in Slots : Persisted(i)

Spec == Init /\ [][Next]_vars

\* --- Invariants -----------------------------------------------------------

Inv_PinAccepted ==
    \A h \in Hosts : pins[h] # None => << h, pins[h] >> \in accepted

Inv_PassPinned ==
    ev.kind = "pass" => (ev.accepted /\ (ev.how = "pin" => ev.pinned))

Inv_LateAnswer == (ev.kind = "write" /\ ev.late) => ev.shown

Inv_NoAskInPortal == ev.kind = "ask" => ~ev.portal

Inv_NoWebPinPassInPortal ==
    (ev.kind = "pass" /\ ev.how = "pin" /\ ev.client = "web") => ~ev.portal

Inv_DeclinedNotAsked == ev.kind = "ask" => ~ev.declinedBefore

Open == {i \in Slots : ch[i].pc = "prompt"}
Inv_OneAtATime ==
    \A i, j \in Open :
        i # j => Key(ch[i].host, ch[i].cert) # Key(ch[j].host, ch[j].cert)

\* --- What the spec says and the code does not -----------------------------

Inv_NoPinInPortal == ev.kind = "write" => ~ev.portal

Gap_NoPinPassInPortal == (ev.kind = "pass" /\ ev.how = "pin") => ~ev.portal

Inv_ShownOwn == ev.kind = "ask" => ev.own

\* --- Witnesses: each MUST be violated -------------------------------------

\* A pin the user accepted lets a later handshake through, in a webview and
\* in a Dart client.
Reach_PinUsed == ~(ev.kind = "pass" /\ ev.how = "pin" /\ ev.client = "web")
Reach_DartPinUsed == ~(ev.kind = "pass" /\ ev.how = "pin" /\ ev.client = "dart")
\* An answer that lands after its view went away pins what it showed.
Reach_LateAnswerPinned == ~(ev.kind = "write" /\ ev.late)
\* A certificate pinned for its host is held back while the OS reports a
\* portal.
Reach_PinHeldInPortal == ev.why # "portalpin"
\* A declined certificate met again, on another host, is cancelled without
\* a prompt.
Reach_DeclinedQuiet == ev.why # "declined"
\* A certificate met while its prompt is open is cancelled without another.
Reach_Coalesced == ev.why # "asking"

=============================================================================
