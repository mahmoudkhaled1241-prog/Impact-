# Impact for Learning & Development — Asset Checklist

All 29 pages of the site are built and functional: header nav (with Solutions
and International Partners mega-menus on hub pages, a lightweight flat nav on
partner and Impact GO detail pages), EN/AR language toggle with RTL support,
coverflow carousels, crossfade slideshows, tabbed content sections, and
footers all work with no external dependencies (no Three.js, no proprietary
Claude Design runtime — plain HTML/CSS/vanilla JS throughout). Every internal
page link (`href="*.dc.html"`) has been verified to resolve to an actual file
in this folder.

The site currently runs on 27 real image files in `assets/`. The remaining
image references below point to filenames that don't exist yet — the pages
render correctly around them (broken-image icon in place of the graphic;
layout, text, and interactivity are unaffected), but a developer needs to
drop in the real files before shipping.

## `Impact L&D Parallax.dc.html` (homepage) — fully asset-complete

- `aim-logo-gradient.png` has a white matte background baked in (not
  transparent). It's shown at 55% width on a dark tile in the numbered
  services panel (service #3, AIM), so a transparent-background re-export
  would look cleaner there.
- `contact-photo.png` is the same office photo used for
  `brand-meeting-ripple.jpeg` elsewhere on the page (reused intentionally,
  per the source material provided) — swap in a dedicated photo for the
  Contact section if a distinct one becomes available later.

## `Partner KnolSkape.dc.html` — fully asset-complete

All 5 carousel images (`cp-coaching-sim.png`, `cp-comm-sim.png`,
`cp-ei-at-work.png`, `cp-gp.png`, `cp-ilead.png`) and the logo variants
(`partner-knolskape-color.png`, `partner-knolskape-dark.png`) are in place.

## Missing assets by page

Every filename below is referenced by its page's `<img src="assets/...">`
exactly as listed — drop the real file in at that path and no code changes
are needed.

### About Impact.dc.html
- `ceo-mahmoud-embaby.png` — CEO headshot, square crop
- `cfo-kareem-abdullah.jpeg` — CFO headshot, square crop

### Assessments & Coaching.dc.html
- `gallup-cliftonstrengths-only.png`
- `partner-bcon-mark.png`

### Balance & Wellbeing.dc.html
- `logo-bounceback.png`
- `logo-relax.png`

### Business Professionalism.dc.html
- `logo-gentlemens-agreement.png`
- `logo-proffwrite.png`

### Gamified Themes.dc.html
- `theme-formula1.png`
- `theme-quantum-break.png`
- `theme-superhero-rivals.png`
- `theme-survival-island.png`
- `theme-treasure-hunt.png`

### Impact GO.dc.html
- `brand-building-ripple.png`

### Impact GO Theme.dc.html
- `theme-funfactory.png`
- `theme-laylaelkabira.png`
- `theme-neonbuzz.png`
- `theme-olympics.png`
- `theme-squad.png`
- `theme-survivors.png`
- `theme-tribes.png`
- (`theme-pirates.png` already exists)

### Impact GO Fun.dc.html
- `gallery-team1.png`
- `gallery-pirate1.png`
- `gallery-pirate2.png`
- `gallery-pirate3.png`
- `gallery-squad1.png` through `gallery-squad6.png` (6 files)
- `gallery-tribes1.png` through `gallery-tribes5.png` (5 files)
- `gallery-laylaelkabira1.png` through `gallery-laylaelkabira3.png` (3 files)

### Impact GO Learn.dc.html
- `logo-fivebehaviors.png`
- `logo-goodtogreat.png`
- `logo-strengthsfinder.png`
- (`partner-culture.png` already exists)

### In-House Games.dc.html
- `logo-context.png`
- `logo-drowning.png`
- `logo-elementalquest.png`
- `logo-mta.png`
- `logo-rescue.png`
- `logo-shadowsignal.png`
- `logo-smartworkers.png`

### International Partners.dc.html
- `partner-bcon-mark.png` (same file as referenced by Assessments & Coaching)

### Interpersonal Skills.dc.html
- `logo-insync.png`
- `logo-intelligence-matters.png`
- `logo-thirdway.png`
- `program-fivebehaviors.png`
- `program-gameofpersuasion.png`
- `program-interlink.png`
- `program-leapupwards.png`
- `program-powerwithoutposition.png`
- `program-smarttalk.png`

### L&D Solutions.dc.html
- `brand-building-ripple.png`
- `brand-handshake-ripple.png`

### Leading Business.dc.html
- `logo-decisionarchitect.png`
- `logo-fastforward.png`
- `logo-fromscratch.png`
- `logo-livingintoplan.png`
- `logo-pmp.png`
- `logo-valuearchitect.png`
- `program-balancedscorecard.png`
- `program-bigpicture.png`
- `program-superheroes.png`
- `program-talkingnumbers.png`
- `program-tempo.png`

### Leading Functions.dc.html
- `logo-ageofcx.png`
- `logo-beourguest.png`
- `logo-beyondcustomersatisfaction.png`
- `logo-buildthebond.png`
- `logo-contacttocontract.png`
- `logo-exsell.png`
- `logo-icare.png`
- `logo-kamleap.png`
- `logo-learningarchitect.png`
- `logo-mark.png` — small corner watermark shown on every Sales & HR carousel card
- `logo-objectiontoconnection.png`
- `logo-protrainer.png`
- `logo-readyconvertboost.png`
- `logo-sealthedeal.png`
- `logo-sellingbynature.png`
- `logo-sellingbynature2.png`

### Leading People.dc.html
- `logo-icoach.png`
- `logo-jugglemaster.png`
- `logo-mbo.png`
- `program-bosstocoach.png`
- `program-brandnewmanager.png`
- `program-firstbreaktherules.png`
- `program-watchfulleader.png`

### One Days Program.dc.html
- `logo-jobdna.png`
- `logo-makinganame.png`
- `logo-timemaster.png`
- `program-artofdelegation.png`
- `program-bounceback2.png`
- `program-bridging.png`
- `program-connect.png`
- `program-designthinking2.png`
- `program-feedbackspiral.png`
- `program-gentlemensagreement2.png`
- `program-leadershipchallenge.png`
- `program-masteringchangecurve.png`
- `program-problemsolved2.png`
- `program-teninnovation.png`
- `program-thirdway.png`

### Partner BCon.dc.html
- `bcon-accountability.png`
- `bcon-innovative-thinking.png`
- `bcon-lifo.png`

### Partner Culture Partners.dc.html
- `cp-countdown.png`
- `cp-impact5.png`
- `cp-neonbuzz.png`
- `cp-rightturns.png`
- `cp-zodiak-sales.png`
- `cp-zodiak-strategy.png`

### Partner Gallup.dc.html
- `gallup-captivate.png`
- `gallup-cliftonstrengths-only.png` (same file as referenced by Assessments & Coaching)
- `gallup-power-maximized-group.png`
- `gallup-power-maximized-individual.png`

### Personal Effectiveness.dc.html
- `program-agileway.png`
- `program-designthinking.png`
- `program-grow.png`
- `program-hardhats.png`
- `program-lepenseur.png`
- `program-lostoasis.png`
- `program-neverland.png`
- `program-problemsolved.png`
- `program-think2act.png`

### Solutions.dc.html
- `brand-handshake-ripple.png` (same file as referenced by L&D Solutions)

---

**Total: 108 unique missing filenames** (129 references across pages, several
files reused — e.g. `partner-bcon-mark.png`, `gallup-cliftonstrengths-only.png`,
`brand-handshake-ripple.png`, `brand-building-ripple.png`). Once these are
dropped into `assets/` with the exact filenames above, every page on the site
is complete with no further code changes required.
