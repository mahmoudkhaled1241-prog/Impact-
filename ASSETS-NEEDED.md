# Assets needed for `Impact L&D Parallax.dc.html`

This page is fully built and functional — header nav, EN/AR language toggle, hero,
partner coverflow slider, numbered services panel, trusted-by marquee, animated
stat counters, "Why Impact" cards, contact section, and footer all work with no
external dependencies (no Three.js, no proprietary Claude Design runtime — plain
HTML/CSS/vanilla JS, same convention as `Partner KnolSkape.dc.html`).

It references image files under `assets/` that still need to be dropped in. Until
then, those spots will show as broken images; everything else (layout, animation,
language switch, slider, hover states) works correctly.

## Already in `assets/`
- `logo.png` — Impact logo (reused from the KnolSkape page)
- `partner-bcon.png` — BCon / LIFO logo (from an uploaded export, transparent)
- `aim-logo-gradient.png` — AIM gradient wordmark (from an uploaded export —
  **has a white matte background baked in**, not transparent. It's shown at
  55% width on a dark tile in the "Numbered services" panel (service #3), so a
  transparent-background re-export from the design project would look better here.)

## Still needed
| File | Used in |
|---|---|
| `meeting.png` | Hero background, services tiles #1 & #4 |
| `handshake.png` | Services tiles #2 & #7 (cycling) |
| `impactgo-logo.png` | Services tile #5 (Impact GO) |
| `brand-skyline-ripple.jpeg` | Services tile #6 (cycling) |
| `tower.png` | Services tile #6 (cycling) |
| `brand-boardroom-ripple.jpeg` | Services tile #7 (cycling), Trusted-by section background |
| `brand-meeting-ripple.jpeg` | Services tile #7 (cycling) |
| `theme-pirates.png` | Services tile #8 |
| `c-vodafone.png`, `c-orange.png`, `c-pepsico.png`, `c-nissan.png` | Trusted-by marquee |
| `partner-culture.png` | Partner slider card 1 |
| `partner-knolskape-dark.png` | Partner slider card 2 |
| `partner-gallup.png`, `gallup-certified-badge.png` | Partner slider card 4 |
| `partner-managementdrive.png` | Partner slider card 5 |
| `contact-photo.png` | Contact section background photo |

Drop the real files into `assets/` using these exact names and the page needs
no other changes.
