function hotspot-on --description 'Spin up the Black Hat Python Lab Hotspot'
    if test (sysctl -n net.ipv4.ip_forward) -eq 0
        echo -e "\e[1;33m[!] Warning: System is in SECURE mode (IP forwarding is disabled).\e[0m"
        echo -e "\e[1;36m[i] Run: sudo sysmode cyber to enable forwarding for hotspot routing.\e[0m"
    end
    nmcli device wifi hotspot ssid BlackHatLab password password123
end
