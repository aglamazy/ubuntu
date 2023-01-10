// USAGE cat env_file | ts-node azure_env2env.ts > .env

process.stdin.on('data', data => {
	const settings = JSON.parse(data.toString());
	for (let i = 0; i< settings.length; i ++) {
		process.stdout.write(settings[i].name + '=' + settings[i].value + '\n');
	}
})
