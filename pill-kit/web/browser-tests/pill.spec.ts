import {test,expect,type Page} from "@playwright/test";
test.beforeEach(async({page})=>{await page.goto("/");});
async function expectPillGeometry(page:Page,width:number){
 const pill=page.locator(".imrse-pill");
 expect(await pill.boundingBox()).toMatchObject({width,height:52});
 await expect(pill).toHaveCSS("border-radius","26px");
}
test("hidden until invoked; Escape removes surface",async({page})=>{
 await expect(page.locator(".imrse-pill")).toHaveCount(0);await page.getByText("Invoke pill",{exact:true}).click();
 await expect(page.getByRole("textbox",{name:"What should I change?"})).toBeFocused();
 await expectPillGeometry(page,360);
 await page.setViewportSize({width:320,height:720});await expectPillGeometry(page,280);
 await page.keyboard.press("Escape");await expect(page.locator(".imrse-pill")).toHaveCount(0);
});
test("original loader stays mounted while status words change",async({page})=>{
 await page.getByText("Invoke pill",{exact:true}).click();await page.keyboard.press("Enter");
 await expect(page.locator(".imrse-word")).toHaveText("Thinking");
 await expect(page.locator('[data-testid="spiral"] svg')).toHaveCount(2);
 await expectPillGeometry(page,240);
 await page.evaluate(()=>{(window as any).loaderNode=document.querySelector('[data-testid="spiral"] svg');});
 const before=await page.locator(".imrse-pill").boundingBox();
 await expect(page.locator(".imrse-word")).toHaveText("Refining",{timeout:4000});
 await expectPillGeometry(page,240);
 expect(await page.evaluate(()=>(window as any).loaderNode===document.querySelector('[data-testid="spiral"] svg'))).toBe(true);
 expect((await page.locator(".imrse-pill").boundingBox())?.width).toBe(before?.width);
 await page.keyboard.press("Escape");await expect(page.locator(".imrse-pill")).toHaveCount(0);
});
test("blank input routes to default.md",async({page})=>{await page.getByText("Invoke pill",{exact:true}).click();await page.keyboard.press("Enter");await expect(page.getByTestId("last-instruction")).toHaveText("Uses default.md");});
test("Command-1 fills preset but does not submit",async({page})=>{await page.getByText("Invoke pill",{exact:true}).click();await page.keyboard.press("Meta+1");await expect(page.getByRole("textbox")).toHaveValue("Expand this while preserving my intent.");await expect(page.locator(".imrse-pill")).toHaveAttribute("data-phase","input");});
test("IME Enter does not submit",async({page})=>{await page.getByText("Invoke pill",{exact:true}).click();await page.getByRole("textbox").dispatchEvent("keydown",{key:"Enter",isComposing:true,keyCode:229});await expect(page.locator(".imrse-pill")).toHaveAttribute("data-phase","input");});
test("real completion ends with no resting pill",async({page})=>{await page.getByText("Invoke pill",{exact:true}).click();await page.keyboard.press("Enter");await expect(page.locator(".imrse-pill")).toHaveAttribute("data-phase","applying",{timeout:17000});await expectPillGeometry(page,220);await expect(page.locator(".imrse-pill")).toHaveAttribute("data-phase","success",{timeout:1000});await expectPillGeometry(page,180);await expect(page.locator(".imrse-pill")).toHaveCount(0,{timeout:4000});});
test("reduced motion uses static original artwork",async({page})=>{await page.emulateMedia({reducedMotion:"reduce"});await page.getByText("Invoke pill",{exact:true}).click();await page.keyboard.press("Enter");await expect(page.locator(".imrse-still-spiral svg")).toHaveCount(1);await expect(page.locator(".imrse-word")).toHaveText("Thinking");await expectPillGeometry(page,240);});
test("failure remains visible until dismissed",async({page})=>{await page.getByRole("combobox").selectOption("error");await page.getByText("Invoke pill",{exact:true}).click();await page.keyboard.press("Enter");await expect(page.locator('.imrse-pill [role="alert"]')).toHaveText("Couldn't update the selection",{timeout:16000});await expectPillGeometry(page,300);await page.getByLabel("Dismiss error").click();await expect(page.locator(".imrse-pill")).toHaveCount(0);});
