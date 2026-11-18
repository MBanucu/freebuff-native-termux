package io.github.mbanucu.freebuffnative;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.Until;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.regex.Pattern;

/**
 * The denial path, in its own run.
 *
 * <p>Revoking a dangerous permission kills the app process, and the test runner
 * lives in that process, so this case cannot share a run with the others.  The
 * script revokes the permission before starting this class and grants it again
 * afterwards.
 */
@RunWith(AndroidJUnit4.class)
public final class DeniedPermissionTest {

    private static final String PACKAGE = "io.github.mbanucu.freebuffnative";

    private UiDevice device;

    @Before
    public void openApp() throws Exception {
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
        // No grant here on purpose: this run tests what happens without it.
        device.executeShellCommand("am start -W -n " + PACKAGE + "/.MainActivity");
        assertTrue("the app starts",
                device.wait(Until.hasObject(By.text("Check setup")), 20_000));
    }

    @Test
    public void asksForThePermissionAndExplainsADenial() throws Exception {
        device.findObject(By.text("Check setup")).click();
        UiObject2 allow = device.wait(
                Until.findObject(By.text(Pattern.compile("(?i)allow"))), 10_000);
        assertNotNull("Android asks for Termux's permission", allow);

        device.pressBack();
        assertTrue("the app explains the denial instead of failing silently",
                device.wait(Until.hasObject(By.text("Permission needed")), 10_000));
        assertTrue("the explanation points at the app settings",
                device.hasObject(By.text(Pattern.compile("(?i)open settings"))));
    }
}
