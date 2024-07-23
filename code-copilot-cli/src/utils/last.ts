const fs = require('fs');

// Function to get the highest existing file number
export function getLastFileNumber() {
    const files = fs.readdirSync('.');
    let maxNumber = 0;
    files.forEach((file: string) => {
        const match = file.match(/modifications(\d+)\.sh$/);
        if (match) {
            const number = parseInt(match[1]);
            if (number > maxNumber) {
                maxNumber = number;
            }
        }
    });
    return maxNumber;
}

