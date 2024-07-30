const fs = require('fs');
const clipboardy = require('clipboardy');

// Read from clipboard
const input = clipboardy.readSync();
const lines = input.split('\n');
let currentFile = null;

lines.forEach(line => {
    if (line.match(/^\/\/\s+([a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+)$/)) {
        currentFile = line.slice(3).trim();
        // Ensure the file is empty before writing new content
        fs.writeFileSync(currentFile, '');
    } else if (currentFile) {
        fs.appendFileSync(currentFile, line + '\n');
    }
});

console.log('File contents replaced successfully.');

