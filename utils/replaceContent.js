import fs from 'fs';
import path from 'path';
import clipboardy from 'clipboardy';

// Read from clipboard
const input = clipboardy.readSync();
const lines = input.split('\n');
let currentFile = null;
let isFirstContentLine = true;

lines.forEach(line => {
    if (line.match(/^\/\/\s+([a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+)$/)) {
        if (currentFile) {
            // Append a newline to separate content blocks
            fs.appendFileSync(currentFile, '\n');
        }
        currentFile = line.slice(3).trim();

        // If path starts with /, replace with ./
        if (currentFile.startsWith('/')) {
            currentFile = `.${currentFile}`;
        }

        // Ensure the directory exists
        const dir = path.dirname(currentFile);
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }

        isFirstContentLine = true;
        // Ensure the file is empty before writing new content
        fs.writeFileSync(currentFile, '');
    } else if (currentFile) {
        if (isFirstContentLine) {
            console.log("Writing", currentFile);
            fs.appendFileSync(currentFile, `// ${currentFile}\n`);
            isFirstContentLine = false;
        }
        fs.appendFileSync(currentFile, line + '\n');
    }
});

console.log('File contents replaced successfully.');
