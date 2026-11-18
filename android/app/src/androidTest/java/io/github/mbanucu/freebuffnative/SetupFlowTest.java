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
import org.junit.FixMethodOrder;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.MethodSorters;

import java.io.File;
import java.util.regex.Pattern;

/**
 * Drives the app on a device through accessibility, not through screenshots.
 *
 * <p>UI Automator subscribes to accessibility events, so every wait here
 * resolves the moment the UI changes; there is nothing to poll and no sleep.
 * The Termux side is real: the check goes out as a RUN_COMMAND and its result
 * has to come back before the assertion passes.
 *
 * <p>Runs with {@code adb shell am instrument}; see test/android-e2e.py.
 */
@RunWith(AndroidJUnit4.class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
public final class SetupFlowTest {

    private static final String PACKAGE = "io.github.mbanucu.freebuffnative";
    private static final String PERMISSION = "com.termux.permission.RUN_COMMAND";
    private static final long SHORT = 10_000;
    private static final long LONG = 120_000;

    private UiDevice device;

    @Before
    public void openApp() throws Exception {
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
        device.executeShellCommand("pm grant " + PACKAGE + " " + PERMISSION);
        device.executeShellCommand("am start -W -n " + PACKAGE + "/.MainActivity");
        assertTrue("the app starts and sees Termux",
                device.wait(Until.hasObject(By.text("Termux is installed.")), 20_000));
    }

    @Test
    public void aMainScreenOffersTheThreeActions() throws Exception {
        assertNotNull("setup", device.findObject(By.text("Set up freebuff-native")));
        assertNotNull("check", device.findObject(By.text("Check setup")));
        assertNotNull("open Termux", device.findObject(By.text("Open Termux")));
        shot("01-main.png");
    }

    @Test
    public void bConsentDialogStatesTheDownload() throws Exception {
        device.findObject(By.text("Set up freebuff-native")).click();
        assertTrue("the dialog appears",
                device.wait(Until.hasObject(By.text("Download about 540 MB?")), SHORT));
        UiObject2 message = device.wait(
                Until.findObject(By.textContains("freebuff-native --download")), SHORT);
        assertNotNull("the dialog shows the command it will run", message);
        String text = message.getText();
        assertTrue("the sizes are in the dialog", text.contains("136 MB") && text.contains("400 MB"));
        assertTrue("the source is named", text.contains("install.sh"));
        shot("02-consent.png");

        device.findObject(By.text("CANCEL")).click();
        assertTrue("cancel closes the dialog",
                device.wait(Until.gone(By.text("Download about 540 MB?")), SHORT));
    }

    @Test
    public void cCheckReportsThroughTermux() throws Exception {
        device.findObject(By.text("Check setup")).click();
        UiObject2 output = device.wait(
                Until.findObject(By.textContains("native install complete")), LONG);
        assertNotNull("Termux returns the check output", output);
        String report = output.getText();
        assertTrue("the check exited 0", report.contains("exit code 0"));
        assertTrue("the report names the shim", report.contains("spawn shim present"));
        assertTrue("the background check stays in the app",
                device.hasObject(By.pkg(PACKAGE)));
        shot("03-check.png");
    }

    @Test
    public void dDeniedPermissionIsExplainedAndRecovered() throws Exception {
        device.executeShellCommand("pm revoke " + PACKAGE + " " + PERMISSION);
        device.executeShellCommand("am force-stop " + PACKAGE);
        device.executeShellCommand("am start -W -n " + PACKAGE + "/.MainActivity");
        assertTrue("the app is back", device.wait(Until.hasObject(By.text("Check setup")), 20_000));

        device.findObject(By.text("Check setup")).click();
        UiObject2 allow = device.wait(
                Until.findObject(By.text(Pattern.compile("(?i)allow"))), SHORT);
        assertNotNull("Android asks for Termux's permission", allow);

        device.pressBack();
        assertTrue("the app explains the denial",
                device.wait(Until.hasObject(By.text("Permission needed")), SHORT));
        device.findObject(By.text("CLOSE")).click();

        device.executeShellCommand("pm grant " + PACKAGE + " " + PERMISSION);
        device.findObject(By.text("Check setup")).click();
        assertNotNull("the check works after the grant",
                device.wait(Until.findObject(By.textContains("exit code 0")), LONG));
    }

    private void shot(String name) throws Exception {
        File dir = new File(InstrumentationRegistry.getInstrumentation()
                .getTargetContext().getExternalFilesDir(null), "screenshots");
        assertTrue("screenshot directory", dir.isDirectory() || dir.mkdirs());
        assertTrue("screenshot " + name, device.takeScreenshot(new File(dir, name)));
    }
}
