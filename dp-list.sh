#!/bin/bash

package=$1

get_deps() {
    for dep in $(yum deplist "$1" | grep "  dependency" | awk '{print $4}'); do
        echo "$dep"
        get_deps "$dep"
    done
}

echo "$package"
get_deps "$package"
