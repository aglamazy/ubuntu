const currentDate = new Date();

console.log(process.argv);
const year = currentDate.getFullYear();
const month = process.argv.length > 2 ? parseInt(process.argv[2]) : currentDate.getMonth() + 1;
const day = currentDate.getDate();

let sum = 0;
let sumUpNow = 0;
const months = [
  "z", "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
];
function isWeekend(day) {
  return day === 5 || day === 6; // Sunday is 0, Saturday is 6
}

function number_of_month(year, month) {
  return new Date(year, month, 0).getDate();
}

console.log("number of days in month: " + number_of_month(year, month));

for (let i = 1; i <= number_of_month(year, month); i++) {
  if (isWeekend(new Date(year, month - 1, i).getDay())) {
    continue; // Skip if it's Friday or Saturday
  }
  let dayHours = 0;

  if (new Date(year, month - 1, i).getDay() >= 0 && new Date(year, month - 1, i).getDay() <= 3) {
    dayHours = 9; // Add 9 hours for Sunday to Wednesday
	console.log(`${i} 9`);
  } else {
	console.log(`${i} 8`);
    dayHours = 8; // Add 8 hours for Thursday
  }
  sum+=dayHours;
  if (i < day) sumUpNow += dayHours;
}

console.log(`Total working hours for ${months[month]} ${year}:`, sum);
if (currentDate.getMonth() + 1 == month) {
	console.log(`Total upto now: ${sumUpNow}`);
}
