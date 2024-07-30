import * as readline from "node:readline";

export async function getCommandsFromStdio(): Promise<string[]> {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout
    });

    const lines: string[] = [];
    console.log('Please enter commands, and press Enter twice to finish:');

    return new Promise<string[]>((resolve) => {
        rl.on('line', (input) => {
            if (input.trim() === '') {
                rl.close();
            } else {
                lines.push(input);
            }
        });

        rl.on('close', () => {
            resolve(lines);
        });
    });
}