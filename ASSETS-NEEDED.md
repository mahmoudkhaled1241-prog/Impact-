# Assets for `Impact L&D Parallax.dc.html`

The page is fully built, functional, and all assets are in place — header nav,
EN/AR language toggle, hero, partner coverflow slider, numbered services panel,
trusted-by marquee, animated stat counters, "Why Impact" cards, contact section,
and footer all work with no external dependencies (no Three.js, no proprietary
Claude Design runtime — plain HTML/CSS/vanilla JS, same convention as
`Partner KnolSkape.dc.html`). Verified rendering console-clean in a headless
browser with every asset loaded.

## One thing worth a developer's second look

- `aim-logo-gradient.png` — has a white matte background baked in (not
  transparent). It's shown at 55% width on a dark tile in the "Numbered
  services" panel (service #3, AIM), so a transparent-background re-export
  would look cleaner there.
- `contact-photo.png` is the same office photo used for
  `brand-meeting-ripple.jpeg` elsewhere on the page (reused intentionally,
  per the source material provided) — swap in a dedicated photo for the
  Contact section if a distinct one becomes available later.

All other assets are the real, final files.
