from pathlib import Path
from playwright.sync_api import sync_playwright

root=Path(__file__).parent
out=root/'screens'
out.mkdir(exist_ok=True)
url='http://127.0.0.1:8765/index.html'
with sync_playwright() as p:
    browser=p.chromium.launch(headless=True, executable_path='/usr/bin/chromium', args=['--no-sandbox'])
    page=browser.new_page(viewport={'width':1200,'height':760}, device_scale_factor=1)
    for section in ['general','models','presets','shortcuts','advanced','about']:
        page.goto(url+f'?section={section}')
        page.screenshot(path=str(out/f'{section}.png'), full_page=True)
    page.goto(url+'?section=presets')
    page.locator('.presetEdit').nth(2).click()
    page.screenshot(path=str(out/'preset-editor.png'), full_page=True)
    page.goto(url+'?section=models')
    page.locator('#addProvider').click()
    page.screenshot(path=str(out/'add-provider.png'), full_page=True)
    page.goto(url+'?section=advanced')
    page.locator('#diagnostics').click()
    page.screenshot(path=str(out/'diagnostics.png'), full_page=True)
    browser.close()
print('captured', len(list(out.glob('*.png'))), 'screens')
