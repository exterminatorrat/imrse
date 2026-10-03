import {defineConfig} from "@playwright/test";
export default defineConfig({testDir:"./browser-tests",use:{baseURL:"http://127.0.0.1:3000"},webServer:{command:"npm run dev",url:"http://127.0.0.1:3000",reuseExistingServer:!process.env.CI},timeout:30000});
