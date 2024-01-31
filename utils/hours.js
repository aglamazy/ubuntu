const year = 2024;
const month = 1;
let sum = 0;

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

  if (new Date(year, month - 1, i).getDay() >= 0 && new Date(year, month - 1, i).getDay() <= 3) {
    sum += 9; // Add 9 hours for Sunday to Wednesday
	console.log(`${i} 9`);
  } else {
	console.log(`${i} 8`);
    sum += 8; // Add 8 hours for Thursday
  }
}

console.log("Total working hours for January 2024:", sum);
