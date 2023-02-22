const readline = require('readline');

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

let input = '';

rl.on('line', (line: string) => {
    input += line + '\n';
});

rl.on('close', () => {
    // process input
    const vars = JSON.parse(input);
    vars.forEach((definition: any) => {
        console.log(definition.name, "=", definition.value)
    })
});
