update:
	sudo apt update
	sudo apt install --only-upgrade google-chrome-stable

.git_installed:
	sudo apt install git
	touch .git_installed

.curl:
	sudo apt install curl
	touch .curl

.speedcrunch:
	sudo apt-get install speedcrunch
	touch .speedcrunch

.wordpress:
	sudo apt update
	sudo apt install wordpress php libapache2-mod-php mysql-server php-mysql

.system:
	sudo apt install gparted

.xdebug:
	sudo apt-get install php-xdebug
	touch .xdebug

.gimp:
	sudo apt-get install gimp
	touch .gimp

.chrome:
	./install_chrome
	touch .chrome

.phpstorm:
	sudo snap install phpstorm --classic
	touch $@

.webstorm:
	sudo snap install webstorm --classic
	touch $@

.datagrip:
	sudo snap install datagrip --classic
	touch $@

.rclone:
	sudo -v ; curl https://rclone.org/install.sh | sudo bash
	touch .rclone	

.node:
	sudo snap install node --channel=18/stable --classic
	touch .node

.gettext:
	sudo apt-get install gettext
	touch .gettext

.sass:
	sudo npm install -g sass
	touch $@


.nvm: .curl
	curl https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
	touch .curl

.compass:
	cd /tmp
	wget https://downloads.mongodb.com/compass/mongodb-compass_1.40.4_amd64.deb
	sudo dpkg -i mongodb-compass_1.40.4_amd64.deb
	touch $@
	
.php:
	sudo apt-get install composer
	touch .php
