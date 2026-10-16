//! Decides whether a 3 / 4 finger movement is a pinch or a swipe.
//!
//! Pure functions, no I/O, so the rules can be tested without a touchpad: `cargo test`.
//!
//! All distances are fractions of the touchpad's span (0.0 .. 1.0):
//!   radial   change of the mean finger distance from the centre of the hand (negative = fingers closing)
//!   dx, dy   how far the centre of the hand moved (dy < 0 = towards the top of the pad)
//!
//! Why this is not "whichever threshold is crossed first": when you pinch with three fingers (thumb + two
//! fingers) the centre of the hand drifts as well. The old rule locked onto whatever crossed its threshold first,
//! and the drift usually won, so a pinch was read as a swipe (3 fingers up / down = scratchpad by default).
//! A real swipe moves the fingers together, so its radial travel is close to zero. A pinch always has a large
//! radial part. So: if the radial travel is at least `pinch_bias` of the drift, it is a pinch.

use std::env;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Undecided,
    PinchIn,
    PinchOut,
    Left,
    Right,
    Up,
    Down,
}

impl Kind {
    /// The suffix of the id used in gestures.conf ("g3-pinchin", "g4-left", ...). None while undecided.
    pub fn name(self) -> Option<&'static str> {
        match self {
            Kind::Undecided => None,
            Kind::PinchIn => Some("pinchin"),
            Kind::PinchOut => Some("pinchout"),
            Kind::Left => Some("left"),
            Kind::Right => Some("right"),
            Kind::Up => Some("up"),
            Kind::Down => Some("down"),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Thresholds {
    /// least radial travel that counts as a pinch (about 1.8 mm on a 100 mm wide pad)
    pub pinch_min: f32,
    /// least movement of the hand that counts as a swipe
    pub swipe_min: f32,
    /// a pinch when radial travel >= drift * pinch_bias. Higher = stricter pinch, lower = pinch wins more often
    pub pinch_bias: f32,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds { pinch_min: 0.018, swipe_min: 0.048, pinch_bias: 0.5 }
    }
}

impl Thresholds {
    /// The defaults, unless HALCYON_PINCH_MIN / HALCYON_SWIPE_MIN / HALCYON_PINCH_BIAS are set (put them in the
    /// systemd unit with Environment=... to tune this for your touchpad without rebuilding).
    pub fn from_env() -> Self {
        let d = Thresholds::default();
        Thresholds {
            pinch_min: env_f32("HALCYON_PINCH_MIN", d.pinch_min),
            swipe_min: env_f32("HALCYON_SWIPE_MIN", d.swipe_min),
            pinch_bias: env_f32("HALCYON_PINCH_BIAS", d.pinch_bias),
        }
    }
}

fn env_f32(name: &str, default: f32) -> f32 {
    match env::var(name).ok().and_then(|v| v.trim().parse::<f32>().ok()) {
        Some(v) if v.is_finite() && v > 0.0 => v,
        _ => default,
    }
}

pub fn classify(t: &Thresholds, radial: f32, dx: f32, dy: f32) -> Kind {
    let rad = radial.abs();
    let drift = (dx * dx + dy * dy).sqrt();

    // pinch first: it wins whenever the fingers moved against each other by a fair share of the total movement
    if rad >= t.pinch_min && rad >= drift * t.pinch_bias {
        return if radial < 0.0 { Kind::PinchIn } else { Kind::PinchOut };
    }

    if drift >= t.swipe_min {
        if dx.abs() > dy.abs() * 1.15 {
            return if dx < 0.0 { Kind::Left } else { Kind::Right };
        }
        return if dy < 0.0 { Kind::Up } else { Kind::Down };
    }

    Kind::Undecided
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t() -> Thresholds {
        Thresholds::default()
    }

    #[test]
    fn clean_pinches() {
        assert_eq!(classify(&t(), -0.03, 0.01, 0.005), Kind::PinchIn);
        assert_eq!(classify(&t(), 0.03, 0.01, 0.0), Kind::PinchOut);
    }

    #[test]
    fn sloppy_pinch_with_hand_drift_is_still_a_pinch() {
        // the case that used to be read as a swipe: the hand drifted 0.04 while the fingers closed by 0.025
        assert_eq!(classify(&t(), -0.025, 0.04, 0.0), Kind::PinchIn);
        assert_eq!(classify(&t(), 0.025, 0.0, -0.04), Kind::PinchOut);
    }

    #[test]
    fn swipes_have_no_radial_travel() {
        assert_eq!(classify(&t(), 0.002, 0.05, 0.0), Kind::Right);
        assert_eq!(classify(&t(), -0.002, -0.05, 0.0), Kind::Left);
        assert_eq!(classify(&t(), 0.0, 0.0, -0.05), Kind::Up);
        assert_eq!(classify(&t(), 0.0, 0.0, 0.05), Kind::Down);
    }

    #[test]
    fn diagonal_swipe_prefers_vertical_unless_clearly_horizontal() {
        assert_eq!(classify(&t(), 0.0, 0.04, 0.04), Kind::Down);
        assert_eq!(classify(&t(), 0.0, 0.06, 0.02), Kind::Right);
    }

    #[test]
    fn small_movement_stays_undecided() {
        assert_eq!(classify(&t(), 0.005, 0.01, 0.01), Kind::Undecided);
        assert_eq!(classify(&t(), 0.0, 0.0, 0.0), Kind::Undecided);
    }

    #[test]
    fn names_match_the_ids_in_gestures_conf() {
        assert_eq!(Kind::PinchIn.name(), Some("pinchin"));
        assert_eq!(Kind::Up.name(), Some("up"));
        assert_eq!(Kind::Undecided.name(), None);
    }
}
