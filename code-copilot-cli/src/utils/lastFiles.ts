import * as fs from 'fs-extra';
import * as path from 'path';

// Function to get all .ts files recursively
async function getAllTsFiles(directory: string): Promise<string[]> {
    let tsFiles: string[] = [];
    const files = await fs.readdir(directory);

    for (const file of files) {
        const fullPath = path.join(directory, file);
        const stat = await fs.stat(fullPath);

        if (stat.isDirectory()) {
            const nestedFiles = await getAllTsFiles(fullPath);
            tsFiles = tsFiles.concat(nestedFiles);
        } else if (file.endsWith('.ts')) {
            tsFiles.push(fullPath);
        }
    }

    return tsFiles;
}

// Function to get the last modified .ts files
export async function getLastModifiedTsFiles(directory: string, count: number): Promise<string[]> {
    const tsFiles = await getAllTsFiles(directory);

    const fileStats = await Promise.all(
        tsFiles.map(async file => ({
            file,
            mtime: (await fs.stat(file)).mtime
        }))
    );

    fileStats.sort((a, b) => b.mtime.getTime() - a.mtime.getTime());

    return fileStats.slice(0, count).map(stat => stat.file);
}
