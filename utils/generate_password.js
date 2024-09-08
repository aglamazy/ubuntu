import generator from 'generate-password';

const args = process.argv.slice(2); // Skip the first two arguments (node and script path)

// Check if --help is included in the arguments
if (args.includes('--help')) {
    console.log(`
Usage: node script.js [options]

Options:
  --length=<number>       Specify the length of the password (default: 32)
  --numbers=<true|false>  Include numbers in the password (default: true)
  --help                  Show this help message
    `);
    process.exit(0);
}

const lengthArg = args.find(arg => arg.startsWith('--length='));
const numbersArg = args.find(arg => arg.startsWith('--numbers='));

const length = lengthArg ? parseInt(lengthArg.split('=')[1]) : 32;
const includeNumbers = numbersArg ? numbersArg.split('=')[1].toLowerCase() === 'true' : true;

const passcode = generator.generate({
    length: length,
    numbers: includeNumbers
});

console.log(passcode);
