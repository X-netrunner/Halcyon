function hotspot-off --description 'Shut down the hotspot'
    nmcli device disconnect wlan0
    if test (sysctl -n net.ipv4.ip_forward) -eq 1
        echo -e "\e[1;32m[+] Hotspot deactivated.\e[0m"
        echo -e "\e[1;36m[i] Note: You can restore maximum protection by running: sudo sysmode secure\e[0m"
    end
end
