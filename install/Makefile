develop: .git_installed .speedcrunch  .system .xdebug .gimp .chrome .phpstorm

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
	sudo apt update
	sudo apt install gparted

.xdebug:
	sudo apt-get install php-xdebug
	touch .xdebug

.gimp:
	sudo apt-get install gimp
	touch .gimp

.chrome: .nala
	./install_chrome
	touch .chrome

.nala:	.phyton
	./install_nala
	touch .nala

.phyton:
	./install_python3
	touch .phyton


.phpstorm:
	./phpstorm
	touch .phpstorm
