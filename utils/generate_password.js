const generator = require('generate-password'); 
  
const passcode = generator.generate({ 
    length: 10, 
    numbers: true
}); 
  
console.log(passcode);
