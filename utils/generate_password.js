const generator = require('generate-password'); 

const passcode = generator.generate({ 
    length: process.argv.length > 1 ? parseInt(process.argv[2]) : 10, 
    numbers: true
}); 
  
console.log(passcode);
