from __future__ import annotations

import os

import pytest


pytestmark = [pytest.mark.browser, pytest.mark.asyncio]


@pytest.fixture
def browser_url() -> str:
    value = os.getenv("ORACLE_BROWSER_URL")
    if not value:
        pytest.skip("Set ORACLE_BROWSER_URL to a running Oracle HMI to enable browser smoke tests.")
    return value.rstrip("/")


async def test_operator_login_and_hmi_shell(browser_url, credentials) -> None:
    playwright = pytest.importorskip(
        "playwright.async_api",
        reason="Playwright is optional; install the [browser] extra to run browser smoke tests.",
    )
    try:
        async with playwright.async_playwright() as pw:
            try:
                browser = await pw.chromium.launch(headless=True)
            except Exception as exc:  # pragma: no cover - depends on local browser installation
                pytest.skip(f"Chromium is unavailable; run `python -m playwright install chromium`: {exc}")
            page = await browser.new_page()
            try:
                await page.goto(browser_url, wait_until="domcontentloaded")
                username = page.locator(
                    "[data-testid='login-username'], input[name='username'], input[autocomplete='username']"
                ).first
                password = page.locator(
                    "[data-testid='login-password'], input[name='password'], input[autocomplete='current-password']"
                ).first
                await username.fill("operator")
                await password.fill(credentials["operator"])
                submit = page.locator("[data-testid='login-submit'], button[type='submit']").first
                await submit.click()
                await page.locator("body").wait_for(state="visible")
                body_text = (await page.locator("body").inner_text()).upper()
                assert "ORACLE" in body_text
                assert "NILIT" in body_text
                assert await page.locator(
                    "[data-testid='logout'], [data-testid='user-menu'], [data-testid='hmi-shell']"
                ).count() > 0
            finally:
                await browser.close()
    except (OSError, RuntimeError) as exc:  # pragma: no cover - local browser/runtime dependent
        pytest.skip(f"Browser runtime unavailable: {exc}")
