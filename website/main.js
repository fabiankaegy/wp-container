// WP Container landing — minimal vanilla JS.
// All motion is gated on the `motion` class (added in <head> only when
// prefers-reduced-motion is "no-preference"). Without it, everything is
// static and fully visible, and this script does no animation work.

(function () {
  'use strict';

  var motion = document.documentElement.classList.contains('motion');

  /* ---- Sticky nav: hairline + shadow once scrolled ---- */
  var nav = document.getElementById('nav');
  if (nav) {
    var onScroll = function () { nav.classList.toggle('scrolled', window.scrollY > 8); };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  /* ---- Copy-to-clipboard ---- */
  document.querySelectorAll('.copy-btn[data-copy]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var target = document.getElementById(btn.getAttribute('data-copy'));
      if (!target) return;
      var text = target.textContent.trim();
      var done = function () {
        btn.classList.add('copied');
        setTimeout(function () { btn.classList.remove('copied'); }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(function () {});
      } else {
        var ta = document.createElement('textarea');
        ta.value = text; document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); done(); } catch (e) {}
        document.body.removeChild(ta);
      }
    });
  });

  // Nothing further to do if motion is off — CSS already shows everything.
  if (!motion || !('IntersectionObserver' in window)) return;

  /* ---- Scroll reveals (once) ---- */
  var reveals = document.querySelectorAll('.reveal');
  var revealObserver = new IntersectionObserver(function (entries, obs) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add('in');
        obs.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });
  reveals.forEach(function (el) { revealObserver.observe(el); });

  /* ---- Terminal: type the command once when scrolled into view ---- */
  var term = document.getElementById('term');
  if (term) {
    var cmdEl = term.querySelector('.term-cmd');
    var full = cmdEl ? (cmdEl.getAttribute('data-cmd') || cmdEl.textContent) : '';
    if (cmdEl) cmdEl.textContent = ''; // clear until typing begins

    var typeCommand = function () {
      term.classList.add('typing');
      var i = 0;
      var step = function () {
        if (i <= full.length) {
          cmdEl.textContent = full.slice(0, i);
          i++;
          // Slight rhythm: pause a touch longer at line breaks.
          var delay = full.charAt(i - 1) === '\n' ? 120 : 16;
          setTimeout(step, delay);
        } else {
          term.classList.remove('typing');
          term.classList.add('done');
        }
      };
      step();
    };

    var termObserver = new IntersectionObserver(function (entries, obs) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          obs.unobserve(entry.target);
          // Let the reveal settle first, then type.
          setTimeout(typeCommand, 260);
        }
      });
    }, { threshold: 0.45 });
    termObserver.observe(term);
  }
})();
