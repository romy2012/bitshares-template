#!/usr/bin/env bash
#
# description:  manage bitshares install/update process
#
# usage: ./bitshares [install|update]
#   install: install: install bitshares on a brand new environment
#   update: update: update bitshares(witness_node, cli_wallet, delayed_node) and web-gui
#   update_gui: only update guid
#
# Author:  Alex Chien <alexchien97@gmail.com>.
#
#------------------------------------------------------------------------------
#                               MIT X11 License
#------------------------------------------------------------------------------
#
# Copyright (c) 2016 Alex Chien (alexchien97@gmail.com)
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#------------------------------------------------------------------------------

# ====================
# = Config Variables =
# ====================
# setup variables
# by default, folder of current script will be the root of installation
#   src, build, opt
# 3 sub-folders will be created
pwd=`pwd -P`
src_dir="$pwd/src"
build_dir="$pwd/build"
opt_dir="$pwd/opt"
boost_root="$opt_dir/boost_1_57_0"
web_root="$build_dir/web_root"

# =============
# = Functions =
# =============
setup_folder_structure(){
    # set up folder structure
    for dir in $src_dir $build_dir $opt_dir; do
      mkdir -p $dir
    done

    # setup wallet website
    mkdir -p $build_dir/web_root
}

install_bitshares_requirements(){
    sudo apt-get update

    # gcc/g++ 4.9
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
    sudo apt-get update
    sudo apt-get install -y gcc-4.9 g++-4.9
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-4.9 60 --slave /usr/bin/g++ g++ /usr/bin/g++-4.9

    sudo apt-get install -y curl git ntp cmake build-essential libbz2-dev libdb++-dev libdb-dev libssl-dev openssl libreadline-dev autoconf libtool libboost-all-dev
    sudo apt-get install -y autotools-dev  libicu-dev python-dev screen nodejs-legacy
    sudo apt-get install -y doxygen libncurses5-dev

    # boost
    mkdir -p $boost_root
    if [[ ! -d "$src_dir/boost_1_57_0" ]]; then
        wget -c 'http://sourceforge.net/projects/boost/files/boost/1.57.0/boost_1_57_0.tar.bz2/download' -O $src_dir/boost_1_57_0.tar.bz2
        cd $src_dir && tar xjf boost_1_57_0.tar.bz2
    fi
    cd $src_dir/boost_1_57_0/ && ./bootstrap.sh "--prefix=$boost_root" && ./b2 install -j$(nproc)
}

update_node(){
    cd $src_dir
    git_args="--init --recursive"

    # check if it's cloned already
    if [[ -d "$src_dir/bitshares-2" ]]; then
        cd $src_dir/bitshares-2
        git pull
        git_args="--recursive"
    else
        git clone https://github.com/bitshares/bitshares-2.git
    fi

    cd $src_dir/bitshares-2
    git submodule update $git_args

    # TODO: find a proper solution
    # missing Doxyfile error
    # https://github.com/cryptonomex/graphene/issues/633
    # reason is we don't make within the source folder, waiting for a official fix
    patch -p1 < $pwd/misc/634.patch

    # make build directory ready
    mkdir -p $build_dir/bitshares-2
    cd $build_dir/bitshares-2

    # delete CMakeCache
    if [[ -f $build_dir/bitshares-2/CMakeCache.txt ]]; then
        rm $build_dir/bitshares-2/CMakeCache.txt
    fi

    # create build.sh for future use
    # if [[ ! -f $build_dir/bitshares-2/build.sh ]]; then
        printf '%s\n%s\n' '#!/bin/sh' "cmake -DBOOST_ROOT=$boost_root -DCMAKE_BUILD_TYPE=Release $src_dir/bitshares-2" "make -j$(nproc)" > build.sh
        chmod +x build.sh
    # fi

    source $build_dir/bitshares-2/build.sh

    # create blockchain data directory
    mkdir -p $build_dir/blockchain_data/logs/witness_node

    # create witness_node.log, without it, witness_node might fail to run
    touch $build_dir/blockchain_data/logs/witness_node/witness_node.log

    # Configure BitShares witeness node to auto start at boot
    # if witness_node already existed, stop it and after several
    # seconds (wait until it's completed stopped)
    if [[ -f /etc/init.d/witness_node ]]; then
        sudo /etc/init.d/witness_node stop
        sleep 20
    fi

    # cp compiled binary to /usr/bin
    for binname in witness_node cli_wallet delayed_node; do
      sudo cp $build_dir/bitshares-2/programs/$binname/$binname /usr/bin/
    done

    sudo cp $pwd/misc/witness_node.ini /etc/init.d/witness_node
    sudo sed -i -e "s|PATH_TO_DATA_DIR|$build_dir/blockchain_data|g" /etc/init.d/witness_node
    sudo chmod +x /etc/init.d/witness_node
    sudo update-rc.d witness_node defaults 99 01

    # start witness node
    sudo /etc/init.d/witness_node start
}

update_gui(){
    cd $src_dir
    git_args="--init --recursive"

    # check if it's cloned already
    if [[ -d "$src_dir/bitshares-2-ui" ]]; then
        cd $src_dir/bitshares-2-ui
        git pull
        git_args="--recursive"
    else
        git clone https://github.com/bitshares/bitshares-2-ui.git
    fi

    cd $src_dir/bitshares-2-ui
    git submodule update $git_args

    # get latest node-sass
    cd web; npm install node-sass

    # install dependencies for each fold
    for dir in dl web; do
      cd "$src_dir/bitshares-2-ui/$dir" && npm install
    done
}

get_ip(){
    dig +short myip.opendns.com @resolver1.opendns.com
}

replace_default_connection(){
    # replace ws connection to this server
    # my_ip=`ifconfig eth1 | awk '/inet addr/{print substr($2,6)}'`
    my_ip=`get_ip`
    my_ws="ws://$my_ip/ws"

    # replace wss connection and faucet url
    sed -i -e "s|connection: \"wss://bitshares.openledger.info/ws\"|connection: \"$my_ws\"|g" \
        -e "s|\"wss://bitshares.openledger.info/ws\"|\"$my_ws\",\"wss://bitshares.openledger.info/ws\"|g" \
        -e "s|faucet_address: \"https://bitshares.openledger.info\"|faucet_address: \"https://bts2faucet.dacplay.org\"|g" \
        $src_dir/bitshares-2-ui/dl/src/stores/SettingsStore.js

    cd $src_dir/bitshares-2-ui
    git config user.name `hostname`
    git config user.email "root@`hostname`"
    git add dl/src/stores/SettingsStore.js
    git commit -m 'update connection string'
}

build_gui(){

    cd $src_dir/bitshares-2-ui/web
    # if [[ ! -f build.sh ]]; then
        # generate build.sh for future use
        printf '%s\n%s\n' '#!/bin/sh' \
          '# use this script to build web ui code and deploy to web root' \
          'npm run build' \
          "sudo cp -r $src_dir/bitshares-2-ui/web/dist/* $web_root" \
          "sudo chown -R www-data:www-data $web_root" \
          "sudo chmod -R 775 $web_root"  > ./build.sh
        chmod +x ./build.sh
    # fi

    source $src_dir/bitshares-2-ui/web/build.sh
}

use_nvm(){
    if [[ ! -f "$HOME/.nvm/nvm.sh" ]]; then
        curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.30.2/install.sh | bash
        . "$HOME/.nvm/nvm.sh"
        nvm install v5
    fi
    . "$HOME/.nvm/nvm.sh"
    nvm use v5
    nvm alias default v5

    # to fix issue
    # sh: 1: node: Permission denied
    npm config set user 0
    npm config set unsafe-perm true
    npm install -g sm
}

# if nginx is already installed, skip
install_nginx(){
    if [ ! -x /usr/sbin/nginx ]; then
        # passenger is not required though, but will be needed when self-hosted faucet service
        # is used.  Faucet is a rails web application
        sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7
        sudo apt-get install -y apt-transport-https ca-certificates

        # Add our APT repository
        sudo sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger trusty main > /etc/apt/sources.list.d/passenger.list'
        sudo apt-get update

        # Install Passenger + Nginx
        sudo apt-get install -y nginx-extras passenger

        # prepare conf files
        sudo cp $pwd/nginx/ssl_params /etc/nginx/
        for conf in $pwd/nginx/*.example; do sudo cp $conf /etc/nginx/sites-available/; done
        if [[ -f /etc/nginx/sites-enabled/default ]]; then
            sudo rm /etc/nginx/sites-enabled/default
        fi
        sudo ln -s /etc/nginx/sites-available/web-ui-http.conf.example /etc/nginx/sites-enabled/web-ui-http.conf

        # update root directory
        sudo sed -ie "s,PATH_TO_WEB_ROOT,$web_root,g" /etc/nginx/sites-available/web-ui-http.conf.example
        sudo sed -ie "s,PATH_TO_WEB_ROOT,$web_root,g" /etc/nginx/sites-available/web-ui-https.conf.example

        sudo service nginx reload
    fi
}

command_exists(){
    command -v foo >/dev/null 2>&1 ;
}

update_self(){
    git pull
}

mk_folder_mine(){
    sudo chown -R $USER $pwd
    sudo chown -R www-data:www-data $web_root
}

init(){
    # = Setup Folder Structures =
    setup_folder_structure

    mk_folder_mine
    update_self
}

# ============
# = Commands =
# ============
case "$1" in
    install)
        # init
        init

        # Update Ubuntu and install prerequisites for running BitShares #
        install_bitshares_requirements

        # = Clone BitShares repo and build =
        update_node

        # = Install nodejs, npm using nvm =
        use_nvm

        # = Get bitshare-2-ui gui code =
        update_gui

        # = Replace default ws connection with our witness_node =
        replace_default_connection

        # = Build GUI code and deploy it to web_root =
        build_gui

        # = Install nginx + passenger =
        install_nginx
        ;;
    update)
        # init
        init

        # = Clone BitShares repo and build =
        update_node

        # = Get bitshare-2-ui gui code =
        update_gui

        # = Build GUI code and deploy it to web_root =
        build_gui
        ;;
    update_gui)
        # init
        init

        # = Install nodejs, npm using nvm =
        use_nvm

        # = Get bitshare-2-ui gui code =
        update_gui

        # = Build GUI code and deploy it to web_root =
        build_gui
        ;;
    *)
        echo "Usage: ./bitshares.sh {install|update}"
        echo "install: install bitshares on a brand new environment"
        echo "update: update bitshares(witness_node, cli_wallet, delayed_node) and web-gui"
        echo "update_gui: only update and build web-gui"
        exit 1
        ;;
esac

exit 0