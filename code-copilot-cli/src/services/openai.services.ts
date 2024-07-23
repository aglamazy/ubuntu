import OpenAI from "openai";
import dotenv from "dotenv";

dotenv.config();

const apiKey = process.env.OPENAI_API_KEY;
if (! apiKey) {
    console.log("api key is missing");
    process.exit();
}
const openai = new OpenAI({
    apiKey
});

export const ChatWithGPT = (prompt: string) => {
    return openai.chat.completions.create({
        model: "gpt-3.5-turbo",
        messages: [
            {
                "role": "system",
                content: "You are a TypeScript developer. You will be provided with a coding task. Provide a bash script that inserts new code lines. Skip the explanations - just the bash. if needed yarn install new packages + @types"
            },
            {
                "role": "user",
                "content": prompt
            }
        ],
        temperature: 0.7,
        max_tokens: 2000,
        top_p: 1,
    });
}