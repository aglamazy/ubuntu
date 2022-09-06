#!/bin/bash -f
$file = patch.`date +'%y-%m-%d'` 
tar cvf $file `find . -name '*.php' -mtime 1 -print`
exit
if [ $# == 0 ];
	then echo "No host given. Done"
	exit
fi

for var in "$@"
do
    echo "Sending to $var..."
	ftp $var << EOF
EOF 
done

