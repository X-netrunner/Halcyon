-- Calm motion: everything eases out slowly (fast start, long soft landing), nothing bounces.
-- Speeds are in 100ms units. If a window or workspace feels sluggish, lower these by 1.
hl.curve("soft",    { type = "bezier", points = { {0.22, 1.00}, {0.36, 1.00} } })   -- easeOutQuint: main curve
hl.curve("glide",   { type = "bezier", points = { {0.32, 0.72}, {0.00, 1.00} } })   -- slightly slower start, for slides
hl.curve("settle",  { type = "bezier", points = { {0.16, 1.00}, {0.30, 1.00} } })   -- very quick, very soft end
hl.curve("leave",   { type = "bezier", points = { {0.40, 0.00}, {0.80, 0.50} } })   -- exits: gentle, never abrupt

hl.animation({ leaf = "global",           enabled = true, speed = 6,   bezier = "soft" })

-- windows: they ease in from slightly smaller and fade, and leave the same way
hl.animation({ leaf = "windows",          enabled = true, speed = 6,   bezier = "soft",   style = "popin 90%" })
hl.animation({ leaf = "windowsIn",        enabled = true, speed = 6,   bezier = "soft",   style = "popin 90%" })
hl.animation({ leaf = "windowsOut",       enabled = true, speed = 5,   bezier = "leave",  style = "popin 92%" })
hl.animation({ leaf = "windowsMove",      enabled = true, speed = 6,   bezier = "soft" })

-- fades
hl.animation({ leaf = "fadeIn",           enabled = true, speed = 6,   bezier = "soft" })
hl.animation({ leaf = "fadeOut",          enabled = true, speed = 4,   bezier = "leave" })
hl.animation({ leaf = "fadeSwitch",       enabled = true, speed = 6,   bezier = "soft" })
hl.animation({ leaf = "fadeShadow",       enabled = true, speed = 6,   bezier = "soft" })
hl.animation({ leaf = "fadeDim",          enabled = true, speed = 6,   bezier = "soft" })

-- workspaces slide a short way while fading, which feels much calmer than a full-width slide
hl.animation({ leaf = "workspaces",       enabled = true, speed = 7,   bezier = "glide",  style = "slidefade 8%" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 7,   bezier = "glide",  style = "slidefadevert 12%" })

hl.animation({ leaf = "layers",           enabled = true, speed = 5,   bezier = "soft",   style = "fade" })
hl.animation({ leaf = "border",           enabled = true, speed = 8,   bezier = "soft" })
