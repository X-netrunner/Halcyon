function hotspot-on --description 'Spin up the Black Hat Python Lab Hotspot'
    # The work is in scripts/hotspot.sh, so the quick console (bash) and fish do exactly the same thing.
    bash $HOME/.config/Halcyon/scripts/hotspot.sh on $argv
end
