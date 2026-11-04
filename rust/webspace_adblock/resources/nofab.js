// SPDX-License-Identifier: MIT
//
// Stands in for FuckAdBlock and BlockAdBlock 3.2, with the API their READMEs
// (sitexw/FuckAdBlock, sitexw/BlockAdBlock) document: a constructor,
// FuckAdBlock or BlockAdBlock, and an instance, fuckAdBlock or blockAdBlock,
// made at load unless the page already gave that name a value. An instance
// never detects an ad blocker:
//   on(false, fn), onNotDetected(fn)  fn runs once, a tick later, as after
//                                     the check the library runs at load
//   on(true, fn), onDetected(fn)      fn never runs
//   check()                           runs the waiting not-detected handlers
//                                     a tick later and returns true
//   emitEvent(false)                  runs them now; emitEvent(true) runs none
//   clearEvent()                      drops them
//   setOption(...)                    changes nothing
// Every method but check() returns the instance. Also served as nobab.js:
// uBlock Origin's keeps eval() from running the payloads blockadblock.com's
// generator writes, which no documentation describes, so here it is the
// BlockAdBlock API that is defused.
(function () {
  'use strict';
  class NotDetecting {
    #waiting = [];
    #run = () => {
      for (const fn of this.#waiting.splice(0)) fn();
    };
    setOption() { return this; }
    check() {
      setTimeout(this.#run, 1);
      return true;
    }
    emitEvent(detected) {
      if (!detected) this.#run();
      return this;
    }
    clearEvent() {
      this.#waiting.length = 0;
      return this;
    }
    on(detected, fn) {
      if (!detected && typeof fn === 'function') {
        this.#waiting.push(fn);
        this.check();
      }
      return this;
    }
    onDetected() { return this; }
    onNotDetected(fn) { return this.on(false, fn); }
  }
  for (const [type, instance] of [['FuckAdBlock', 'fuckAdBlock'], ['BlockAdBlock', 'blockAdBlock']]) {
    window[type] = NotDetecting;
    if (window[instance] === undefined) window[instance] = new NotDetecting();
  }
})();
