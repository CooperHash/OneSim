import * as THREE from '/vendor/three.module.min.js';
import { GLTFLoader } from '/vendor/GLTFLoader.js';
import { MeshoptDecoder } from '/vendor/meshopt_decoder.module.js';

const innerWidth = 0.07898555;
const innerHeight = 0.05541209;
const outerMinX = -0.07972508;
const outerMaxX = -0.0023393707;
const outerHeight = 0.056149645;
const rad = Math.PI / 180;
const quarterTurn = Math.PI / 2;

export class DuoModel {
  static async load(stage, panel) {
    const model = await new GLTFLoader().setMeshoptDecoder(MeshoptDecoder).loadAsync('/assets/v68.glb');
    if (!model.animations.length) throw new Error('Missing Duo fold animation');
    return new DuoModel(stage, model, panel);
  }

  constructor(stage, model, panel) {
    this.stage = stage;
    this.panel = panel;
    this.renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true, powerPreference: 'low-power' });
    this.renderer.setPixelRatio(Math.min(2, devicePixelRatio));
    this.canvas = this.renderer.domElement;
    this.canvas.className = 'fold-scene';
    this.canvas.hidden = true;
    this.canvas.setAttribute('aria-label', 'Interactive iPhone Duo model');
    this.canvas.setAttribute('role', 'img');
    stage.append(this.canvas);
    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(24, 1, 0.001, 3);
    this.rig = new THREE.Group();
    this.offset = new THREE.Group();
    this.modelRoot = new THREE.Group();
    this.scene.add(this.rig);
    this.rig.add(this.offset);
    this.offset.add(this.modelRoot);
    this.modelRoot.add(model.scene);
    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x7d87a6, 2.0));
    for (const [x, y, z, intensity] of [[-2, 3, 3, 2], [2, 0, 1, 1.5], [0, -2, -3, 1]]) {
      const light = new THREE.DirectionalLight(0xffffff, intensity);
      light.position.set(x, y, z);
      this.scene.add(light);
    }
    this.mixer = new THREE.AnimationMixer(model.scene);
    this.clip = model.animations[0];
    this.mixer.clipAction(this.clip).setLoop(THREE.LoopOnce, 1).play();
    this.mixer.setTime(0);
    this.rig.updateMatrixWorld(true);
    const left = model.scene.getObjectByName('pXhjqgUFTJHRqSk');
    const right = model.scene.getObjectByName('mXxhFfVnnQRwgSU');
    if (!left || !right) throw new Error('Missing Duo wing bones');
    this.inner = [
      this.plane(left, -innerWidth, 0, 0.002493645, innerHeight),
      this.plane(right, 0, innerWidth, 0.002493645, innerHeight)
    ];
    this.outer = [this.plane(left, outerMinX, outerMaxX, -0.00275370, outerHeight)];
    this.textures = {};
    for (const [side, name] of [['inner', 'CvyXbAGXoolRUYl'], ['outer', 'YqugYDOqMSOpqyA']]) {
      const canvas = document.createElement('canvas');
      // WebGL allocates texture storage on its first upload. Keep its dimensions
      // stable when the actual panel wakes or switches stream encoders.
      canvas.width = canvas.height = 960;
      const texture = new THREE.CanvasTexture(canvas);
      texture.flipY = false;
      texture.colorSpace = THREE.SRGBColorSpace;
      texture.generateMipmaps = false;
      texture.minFilter = THREE.LinearFilter;
      this.textures[side] = { canvas, texture, context: canvas.getContext('2d', { alpha: false }) };
      const live = new THREE.MeshBasicMaterial({ map: texture, side: THREE.DoubleSide, toneMapped: false });
      model.scene.traverse(node => {
        if (node.material?.name !== name) return;
        // The compressed GLB stores quantized UVs and a matching texture transform.
        // Keep that transform when replacing the baked display with the live canvas.
        const original = node.material.emissiveMap;
        if (original) {
          texture.offset.copy(original.offset);
          texture.repeat.copy(original.repeat);
          texture.center.copy(original.center);
          texture.rotation = original.rotation;
        }
        node.material = live;
      });
    }
    this.angle = 180;
    this.angularVelocity = 0;
    this.rotation = new THREE.Quaternion();
    this.rotationTarget = new THREE.Quaternion();
    this.quaternionVelocity = new THREE.Vector4();
    this.ray = new THREE.Raycaster();
    this.lastTick = 0;
    this.resize = new ResizeObserver(() => { if (this.active) this.draw(); });
    this.resize.observe(stage);
  }

  plane(bone, minX, maxX, y, halfHeight) {
    const geometry = new THREE.PlaneGeometry(maxX - minX, 2 * halfHeight);
    const material = new THREE.MeshBasicMaterial({ side: THREE.DoubleSide, visible: false });
    const mesh = new THREE.Mesh(geometry, material);
    mesh.rotation.x = quarterTurn;
    mesh.position.set((minX + maxX) / 2, y, 0);
    this.rig.add(mesh);
    bone.attach(mesh);
    return mesh;
  }

  setPose(state, snap = false) {
    if (!Number.isFinite(state.angle)) return;
    this.target = state.angle;
    this.display = state.activeDisplay || (state.angle <= 45 ? 'outer' : 'inner');
    const base = this.display === 'inner'
      ? new THREE.Quaternion(Math.SQRT1_2, 0, 0, Math.SQRT1_2)
      : new THREE.Quaternion(0.5, 0.5, -0.5, 0.5);
    this.rotationTarget.setFromAxisAngle(new THREE.Vector3(0, 0, 1), -(state.orientation || 0) * quarterTurn)
      .multiply(base);
    if (snap || !this.initialized) {
      this.angle = this.target;
      this.angularVelocity = 0;
      this.rotation.copy(this.rotationTarget);
      this.quaternionVelocity.set(0, 0, 0, 0);
    }
    this.initialized = true;
    this.requestDraw();
  }

  setFrame(image, display, width, height, existingTurns = 0) {
    const destination = this.textures[display];
    if (!destination) return;
    const turns = display === 'inner' && height > width;
    const w = turns ? height : width;
    const h = turns ? width : height;
    const ctx = destination.context;
    const { width: textureWidth, height: textureHeight } = destination.canvas;
    ctx.setTransform(textureWidth / w, 0, 0, textureHeight / h, textureWidth / 2, textureHeight / 2);
    ctx.rotate((Number(turns) - existingTurns) * quarterTurn);
    const sourceWidth = existingTurns % 2 ? height : width;
    const sourceHeight = existingTurns % 2 ? width : height;
    ctx.drawImage(image, -sourceWidth / 2, -sourceHeight / 2, sourceWidth, sourceHeight);
    destination.texture.needsUpdate = true;
    if (this.active) this.requestDraw();
  }

  requestDraw() {
    if (!this.request) this.request = requestAnimationFrame(now => this.tick(now));
  }

  tick(now) {
    this.request = 0;
    const dt = this.lastTick ? Math.min(0.05, (now - this.lastTick) / 1000) : 1 / 60;
    this.lastTick = now;
    const step = (delta, velocity, omega) => {
      const change = (velocity + omega * delta) * dt;
      const decay = Math.exp(-omega * dt);
      return [(delta + change) * decay, (velocity - omega * change) * decay];
    };
    const [delta, speed] = step(this.angle - this.target, this.angularVelocity, 8);
    const hingeMoving = Math.abs(delta) > 0.025 || Math.abs(speed) > 0.07;
    this.angle = hingeMoving ? this.target + delta : this.target;
    this.angularVelocity = hingeMoving ? speed : 0;
    const angles = this.rotation.toArray();
    const sign = this.rotation.dot(this.rotationTarget) < 0 ? -1 : 1;
    const targets = this.rotationTarget.toArray().map(value => value * sign);
    const velocity = this.quaternionVelocity.toArray();
    let turning = false;
    for (let i = 0; i < 4; i++) {
      const [distance, speed] = step(angles[i] - targets[i], velocity[i], 2 / 0.18);
      angles[i] = targets[i] + distance;
      velocity[i] = speed;
      turning ||= Math.abs(distance) > 0.0002 || Math.abs(speed) > 0.001;
    }
    this.rotation.fromArray(angles).normalize();
    this.quaternionVelocity.fromArray(velocity);
    this.active = hingeMoving || (0.5 < this.angle && this.angle < 179.5);
    this.stage.classList.toggle('folding', this.active);
    this.canvas.hidden = !this.active;
    if (this.active) this.draw();
    if (this.active && (hingeMoving || turning)) {
      this.requestDraw();
    } else {
      this.lastTick = 0;
    }
  }

  draw() {
    const width = this.canvas.clientWidth;
    const height = this.canvas.clientHeight;
    if (!width || !height) return;
    const cssScale = parseFloat(getComputedStyle(this.stage).getPropertyValue('--px'));
    this.renderer.setSize(width, height, false);
    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
    const pixelsPerUnit = 180.86 * cssScale * 100;
    this.camera.position.z = 0.0026 + height / (pixelsPerUnit * 2 * Math.tan(12 * rad));
    const fraction = 1 - this.angle / 180;
    this.mixer.setTime(Math.min(this.clip.duration - 0.00001, fraction * this.clip.duration));
    this.modelRoot.rotation.z = -90 * rad * fraction;
    this.offset.position.y = -0.04070 * fraction;
    this.rig.quaternion.copy(this.rotation);
    this.renderer.render(this.scene, this.camera);
  }

  pick(event) {
    if (!this.active) return null;
    const rect = this.canvas.getBoundingClientRect();
    this.ray.setFromCamera({
      x: 2 * (event.clientX - rect.left) / rect.width - 1,
      y: 1 - 2 * (event.clientY - rect.top) / rect.height
    }, this.camera);
    const display = this.panel.state.activeDisplay;
    const planes = display === 'inner' ? this.inner : this.outer;
    const intersection = this.ray.intersectObjects(planes, false)[0];
    if (!intersection?.uv) return null;
    const { x, y } = intersection.uv;
    if (display !== 'inner') return { x: 1 - x, y };
    const u = (x + (intersection.object === planes[0] ? 0 : 1)) / 2;
    return this.panel.state.height > this.panel.state.width ? { x: y, y: 1 - u } : { x: u, y };
  }
}
