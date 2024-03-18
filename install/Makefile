develop: .git_installed .speedcrunch  .system .gimp .chrome .phpstorm .rclone .node .webstorm .datagrip .curl

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
	touch .nvm
