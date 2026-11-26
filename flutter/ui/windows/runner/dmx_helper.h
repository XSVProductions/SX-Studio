#ifndef RUNNER_DMX_HELPER_H_
#define RUNNER_DMX_HELPER_H_

// Runs the DMX output when this program was started as
// `sx_studio.exe --dmx-helper --dir <ShowXpress folder>`, and returns its
// exit code. Returns -1 when it was started as the app.
int RunDmxHelperIfAsked();

#endif  // RUNNER_DMX_HELPER_H_
