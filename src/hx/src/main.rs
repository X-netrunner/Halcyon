mod adapt;
mod ctl;
mod dossier;
mod feeds;
mod focus;
mod ids;
mod palette;
mod specs;
mod portrait;
mod stars;
mod status;
mod sysfeeds;
mod util;
mod wsres;

fn num(a: &[String], i: usize, d: f64) -> f64 {
    a.get(i).and_then(|x| x.parse().ok()).unwrap_or(d)
}

fn usage() {
    eprintln!(
        "hx: Halcyon helper multitool\n\
         island feeds : audio | bt | wifi | disk [secs] | gpu [secs] | specs | wsres [secs] | stats [secs] | net [secs] | states | palette <image> | portrait <image> [grid] [max] | status | ctl | stars <image> [n]\n\
         focus mode   : focus start|stop|toggle|pause|resume|add|skip|status|conf|set|apps|block|unblock (see scripts/focus.sh)\n\
         sysmode      : ids (IDS daemon) | dossier [ip]"
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rest = if args.is_empty() { &[][..] } else { &args[1..] };
    match args.first().map(|s| s.as_str()) {
        Some("audio") => feeds::audio(),
        Some("bt") => feeds::bt(),
        Some("wifi") => feeds::wifi(),
        Some("disk") => feeds::disk(num(rest, 0, 10.0)),
        Some("gpu") => feeds::gpu(num(rest, 0, 2.0)),
        Some("specs") => specs::run_specs(),
        Some("wsres") => wsres::wsres(num(rest, 0, 2.0)),
        Some("ctl") => ctl::run(),
        Some("stars") => stars::run(rest.first().map(|s| s.as_str()).unwrap_or(""), rest.get(1).and_then(|n| n.parse().ok()).unwrap_or(70)),
        Some("portrait") => std::process::exit(portrait::run(
            rest.first().map(|s| s.as_str()).unwrap_or(""),
            rest.get(1).and_then(|n| n.parse().ok()).unwrap_or(160),
            rest.get(2).and_then(|n| n.parse().ok()).unwrap_or(900),
        )),
        Some("status") => status::run(),
        Some("stats") => sysfeeds::stats(num(rest, 0, 2.0)),
        Some("net") => sysfeeds::net(num(rest, 0, 4.0)),
        Some("states") => sysfeeds::states(),
        Some("focus") => std::process::exit(focus::run(rest)),
        Some("ids") => ids::run(),
        Some("dossier") => dossier::run(rest.first().map(|s| s.as_str())),
        Some("palette") => palette::palette(rest.first().map(|s| s.as_str())),
        Some("adapt-sample") => adapt::sample(),
        Some("adapt-status") => adapt::status(),
        Some("adapt-reset") => adapt::reset(),
        _ => {
            usage();
            std::process::exit(2);
        }
    }
}
